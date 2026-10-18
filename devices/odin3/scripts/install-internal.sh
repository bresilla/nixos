#!/usr/bin/env bash
# Installs NixOS on the Odin 3's internal storage in place of Armada, keeping
# Android. Run as root from NixOS on a USB drive, with the internal-storage
# system already built: install-internal.sh /nix/store/...-nixos-system-odin3-...
set -euo pipefail

system=${1:?usage: install-internal.sh SYSTEM}
[[ $EUID == 0 ]] || { echo "install-internal.sh: run as root" >&2; exit 1; }
[[ -x $system/activate ]] || { echo "install-internal.sh: $system is not a NixOS system" >&2; exit 1; }

# Armada's partitions on the internal UFS, by label: never anything else.
root=$(readlink -f /dev/disk/by-partlabel/ARMADA_ROOT 2>/dev/null || readlink -f /dev/disk/by-label/odin3-root)
boot=$(readlink -f /dev/disk/by-label/ARMADA 2>/dev/null || readlink -f /dev/disk/by-label/ODIN3-INT)
for part in "$root" "$boot"; do
  [[ -b $part ]] || { echo "install-internal.sh: partition not found" >&2; exit 1; }
  [[ $(udevadm info -q property "$part" | sed -n 's/^ID_PATH=//p') == platform-1d84000.ufs-* ]] ||
    { echo "install-internal.sh: $part is not on the internal UFS" >&2; exit 1; }
  ! findmnt -rn -S "$part" > /dev/null || { echo "install-internal.sh: $part is mounted" >&2; exit 1; }
done
echo "root: $root ($(lsblk -no SIZE,FSTYPE,LABEL "$root"))"
echo "boot: $boot ($(lsblk -no SIZE,FSTYPE,LABEL "$boot"))"
read -rp "Erase these two partitions and install NixOS? Type yes: " answer
[[ $answer == yes ]] || exit 1

mkfs.ext4 -F -L odin3-root "$root"
fatlabel "$boot" ODIN3-INT
mnt=$(mktemp -d)
mount "$root" "$mnt"
mkdir -p "$mnt/boot"
mount "$boot" "$mnt/boot"
trap 'umount "$mnt/boot" "$mnt" 2>/dev/null || true' EXIT
# Armada's /KERNEL and its spares go; ours is written by the boot hook.
find "$mnt/boot" -mindepth 1 -delete

nixos-install --root "$mnt" --system "$system" --no-root-passwd --no-channel-copy

# Identity, keys, password, networks and the user's data from this system.
mkdir -p "$mnt/etc/nixos" "$mnt/etc/ssh" "$mnt/etc/NetworkManager/system-connections" "$mnt/var/lib"
cp -a /etc/nixos/. "$mnt/etc/nixos/"
cp -a /etc/ssh/ssh_host_* "$mnt/etc/ssh/"
cp -a /etc/NetworkManager/system-connections/. "$mnt/etc/NetworkManager/system-connections/"
cp -a /etc/shadow "$mnt/etc/shadow"
cp -a /var/lib/decky-loader "$mnt/var/lib/" 2> /dev/null || true
rsync -aHAX /home/ "$mnt/home/"
sync
echo "Installed. Set the ABL's Linux boot source to internal and restart."
