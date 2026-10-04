#!/usr/bin/env bash
set -euo pipefail

install_work=""
trap 'if [[ -n "$install_work" ]]; then rm -rf -- "$install_work"; fi' EXIT

die() { echo "error: $*" >&2; exit 1; }

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: install.sh [laptop|server] [path/to/disko.nix]"
    echo "Supply your machine's Disko layout from an x86_64 UEFI NixOS live environment."
    echo "The disks defined in that file will be erased after confirmation."
    return
  fi
  [[ $# -le 2 ]] || die "Usage: install.sh [laptop|server] [path/to/disko.nix]"

  local tool
  for tool in nix nixos-install nixos-enter lsblk mountpoint cp mktemp; do
    command -v "$tool" >/dev/null || die "$tool is missing; boot a NixOS live environment"
  done
  [[ "$(uname -m)" == "x86_64" ]] || die "These configurations target x86_64"
  [[ -d /sys/firmware/efi ]] || die "Boot the live environment in UEFI mode"

  # Read prompts from the terminal even when the script arrives through curl.
  exec 3<>/dev/tty || die "An interactive terminal is required for disk confirmation"
  local role="${1:-}" layout_file="${2:-}" confirmation install_user
  if [[ -z "$role" ]]; then
    read -r -p "Configuration [laptop/server] (laptop): " role <&3
    role="${role:-laptop}"
  fi
  case "$role" in laptop|server) ;; *) die "Configuration must be laptop or server" ;; esac
  if [[ -z "$layout_file" ]]; then
    lsblk -d -o NAME,SIZE,MODEL
    echo "Create a self-contained disko.nix for this machine in another terminal."
    echo "Define your disk devices, partitions, root filesystem, and UEFI mount at /boot."
    read -r -p "Path to your disko.nix: " layout_file <&3
  fi
  [[ -f "$layout_file" ]] || die "Disko file not found: $layout_file; create it first"
  read -r -p "Username for your account: " install_user <&3
  [[ "$install_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$install_user" != root ]] \
    || die "Choose a username of up to 32 lowercase letters, digits, underscores or hyphens, starting with a letter or underscore; root is reserved"
  if mountpoint -q /mnt; then
    die "Unmount /mnt before starting a new installation"
  fi

  local -a as_root=()
  if (( EUID != 0 )); then
    command -v sudo >/dev/null || die "Run as root or install sudo"
    sudo -v <&3
    as_root=(sudo)
  fi

  install_work="$(mktemp -d -t nixos-install.XXXXXXXX)"
  local source_dir="" script_file="${BASH_SOURCE[0]:-}" repo_dir="$install_work/nixos"
  if [[ -f "$script_file" ]]; then
    source_dir="$(cd -- "$(dirname -- "$script_file")" && pwd)"
  elif [[ -f ./flake.nix && -f ./configuration.nix ]]; then
    source_dir="$PWD"
  fi
  if [[ -n "$source_dir" && -f "$source_dir/flake.nix" && -f "$source_dir/configuration.nix" ]]; then
    mkdir -p "$repo_dir"
    cp -a "$source_dir/flake.nix" "$source_dir/flake.lock" \
      "$source_dir/configuration.nix" \
      "$source_dir/modules" "$repo_dir/"
    for tool in README.md install.sh; do
      [[ ! -f "$source_dir/$tool" ]] || cp -a "$source_dir/$tool" "$repo_dir/"
    done
  else
    local repo_url="${NIXOS_REPO_URL:-https://github.com/bresilla/nixos.git}"
    if command -v git >/dev/null; then
      git clone --depth 1 "$repo_url" "$repo_dir"
    else
      nix --extra-experimental-features 'nix-command flakes' \
        shell nixpkgs#git --command git clone --depth 1 "$repo_url" "$repo_dir"
    fi
  fi

  # Install the supplied layout unchanged alongside the universal configuration.
  cp -- "$layout_file" "$repo_dir/disko.nix"
  printf '{ bresilla.user.name = "%s"; }\n' "$install_user" > "$repo_dir/user.nix"
  local flake="path:$repo_dir#nixosConfigurations.$role.config" disk_script
  local -a nix_command=(nix --extra-experimental-features 'nix-command flakes')
  local disk_paths disk mounted
  disk_paths="$("${nix_command[@]}" eval --raw "$flake.disko.devices.disk" \
    --apply 'disks: builtins.concatStringsSep "\n" (map (disk: disk.device) (builtins.attrValues disks))')"
  [[ -n "$disk_paths" ]] || die "Your Disko file must define at least one disk"
  local -a disks
  mapfile -t disks <<< "$disk_paths"
  for disk in "${disks[@]}"; do
    [[ "$disk" == /dev/* && -b "$disk" ]] || die "$disk is not a block device under /dev"
    [[ "$(lsblk -dnro TYPE "$disk")" == "disk" ]] || die "Select a whole disk, not a partition: $disk"
    mounted="$(lsblk -nr -o MOUNTPOINT "$disk")"
    [[ ! "$mounted" =~ [^[:space:]] ]] \
      || die "$disk has mounted partitions or active swap; unmount them first"
    lsblk -d -o NAME,SIZE,MODEL "$disk"
  done
  "${nix_command[@]}" eval --raw "$flake.system.build.toplevel.drvPath" >/dev/null
  disk_script="$("${nix_command[@]}" build --no-link --print-out-paths "$flake.system.build.diskoScript")"

  echo "Install #$role using $layout_file. ALL DATA ON THESE DISKS WILL BE ERASED: ${disks[*]}"
  read -r -p "Type '${disks[*]}' to confirm: " confirmation <&3
  [[ "$confirmation" == "${disks[*]}" ]] || die "Cancelled; no disks were changed"

  "${as_root[@]}" "$disk_script" <&3
  "${as_root[@]}" mkdir -p /mnt/etc/nixos
  "${as_root[@]}" cp -a --no-preserve=ownership "$repo_dir/." /mnt/etc/nixos/
  "${as_root[@]}" nixos-install --root /mnt --flake "path:/mnt/etc/nixos#$role" <&3
  echo "Set the password for $install_user:"
  "${as_root[@]}" nixos-enter --root /mnt -- passwd "$install_user" <&3
  echo "Installed #$role. Configuration: /etc/nixos. Reboot when ready."
}

main "$@"
