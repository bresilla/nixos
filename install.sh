#!/usr/bin/env bash
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo "Usage: install.sh [laptop|server] [path/to/disko.nix]"
  echo "Launch Oslo from an x86_64 UEFI NixOS live environment."
  echo "Choose an existing Disko file or create one through the prompts."
  exit 0
fi
[[ $# -le 2 ]] || die "Usage: install.sh [laptop|server] [path/to/disko.nix]"
for tool in curl tar sha256sum nix nixos-install nixos-enter lsblk mountpoint cp mktemp; do
  command -v "$tool" >/dev/null || die "$tool is missing; boot a NixOS live environment"
done
[[ "$(uname -m)" == x86_64 ]] || die "These configurations target x86_64"
[[ -d /sys/firmware/efi ]] || die "Boot the live environment in UEFI mode"
exec 3<>/dev/tty || die "An interactive terminal is required"

install_work="$(mktemp -d -t nixos-install.XXXXXXXX)"
trap 'rm -rf -- "$install_work"' EXIT
# The normal, static Oslo release: no compilation or permanent installation.
oslo_version="v0.7.2"
oslo_archive="$install_work/oslo.tar.gz"
curl -fsSL "https://github.com/termworks/oslo/releases/download/$oslo_version/oslo-linux-amd64.tar.gz" -o "$oslo_archive"
printf '%s  %s\n' '4294095c41fe8627928b0f9704e4b5ecfdabc5d185286bd9adb19fba649124a3' "$oslo_archive" | sha256sum -c -
tar -xzf "$oslo_archive" -C "$install_work" oslo

source_dir=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
elif [[ -f ./flake.nix && -f ./install.lua ]]; then
  source_dir="$PWD"
fi
repo_dir="$install_work/nixos"
if [[ -n "$source_dir" && -f "$source_dir/flake.nix" && -f "$source_dir/install.lua" ]]; then
  mkdir -p "$repo_dir"
  cp -a "$source_dir/flake.nix" "$source_dir/flake.lock" "$source_dir/configuration.nix" \
    "$source_dir/modules" "$source_dir/install.lua" "$source_dir/install.sh" "$repo_dir/"
  [[ ! -f "$source_dir/README.md" ]] || cp -a "$source_dir/README.md" "$repo_dir/"
else
  repo_url="${NIXOS_REPO_URL:-https://github.com/bresilla/nixos.git}"
  if command -v git >/dev/null; then
    git clone --depth 1 "$repo_url" "$repo_dir"
  else
    nix --extra-experimental-features 'nix-command flakes' \
      shell nixpkgs#git --command git clone --depth 1 "$repo_url" "$repo_dir"
  fi
fi
"$install_work/oslo" --norc "$repo_dir/install.lua" "$repo_dir" "$@" <&3
