#!/usr/bin/env bash
# Run as root after writing the image to a drive: copies this computer's active
# Wi-Fi connection and optionally a login password into the drive's root
# filesystem. Neither enters the image, the Nix store or the repository.
set -euo pipefail

drive=${1:?usage: provision.sh /dev/sdX [username]}
user=${2:-$(logname 2>/dev/null || echo "${SUDO_USER:-}")}
[[ $EUID == 0 ]] || { echo "provision.sh: run as root" >&2; exit 1; }
[[ -b $drive ]] || { echo "provision.sh: $drive is not a block device" >&2; exit 1; }

partprobe "$drive" 2>/dev/null || true
udevadm settle
root=$(lsblk -lnpo NAME,LABEL "$drive" | awk '$2 == "nixos-odin3" { print $1 }')
[[ -n $root ]] || { echo "provision.sh: no nixos-odin3 partition on $drive" >&2; exit 1; }

mnt=$(mktemp -d)
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt"' EXIT
mount "$root" "$mnt"

# Active Wi-Fi connection, as a NetworkManager keyfile.
connections=$mnt/etc/NetworkManager/system-connections
mkdir -p "$connections"
chmod 700 "$connections"
while IFS=: read -r name type; do
  [[ $type == 802-11-wireless ]] || continue
  file=$(grep -lx "id=$name" /etc/NetworkManager/system-connections/*.nmconnection | head -1)
  [[ -n $file ]] || continue
  # The interface name differs on the Odin 3.
  sed '/^interface-name=/d' "$file" > "$connections/$(basename "$file")"
  chmod 600 "$connections/$(basename "$file")"
  echo "copied Wi-Fi connection: $name"
done < <(nmcli -t -f NAME,TYPE con show --active)

# Optional password; activation keeps an existing hash for undeclared passwords.
if [[ -n $user ]] && read -rsp "Password for $user on the Odin 3 (empty skips): " password && echo && [[ -n $password ]]; then
  openssl=(openssl)
  command -v openssl >/dev/null || openssl=(nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#openssl -c openssl)
  hash=$("${openssl[@]}" passwd -6 -stdin <<< "$password")
  printf '%s:%s:1::::::\n' "$user" "$hash" > "$mnt/etc/shadow"
  chmod 600 "$mnt/etc/shadow"
  echo "set the password for $user"
fi

sync
echo "provisioned $root"
