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
for tool in nix nixos-install nixos-enter lsblk mountpoint cp mktemp; do
  command -v "$tool" >/dev/null || die "$tool is missing; boot a NixOS live environment"
done
[[ "$(uname -m)" == x86_64 ]] || die "These configurations target x86_64"
[[ -d /sys/firmware/efi ]] || die "Boot the live environment in UEFI mode"
exec 3<>/dev/tty || die "An interactive terminal is required"

install_work="$(mktemp -d -t nixos-install.XXXXXXXX)"
trap 'rm -rf -- "$install_work"' EXIT
# Normal Oslo 0.7.3, matching the locked Oslo flake; Nix verifies Cachix's signature.
oslo_store="/nix/store/cslpa9c81wgzc6bkg2hnm7qjc6flwsm2-oslo-static-x86_64-unknown-linux-musl-0.7.3"
if [[ ! -x "$oslo_store/bin/oslo" ]]; then
  nix_copy=(nix --extra-experimental-features 'nix-command flakes' copy
    --from https://termworks.cachix.org
    --extra-trusted-public-keys 'termworks.cachix.org-1:Ty7sSVALfD5ajbcWBIdaNHcaEx3fEmVrOo+rSzy0mvE=')
  # A fresh multi-user Nix daemon only accepts a new signing key from a trusted user.
  if (( EUID != 0 )) && [[ -S /nix/var/nix/daemon-socket/socket ]]; then
    command -v sudo >/dev/null || die "sudo is required to load the signed package into the Nix store"
    nix_copy=(sudo "${nix_copy[@]}")
  fi
  "${nix_copy[@]}" "$oslo_store"
fi
oslo_bin="$oslo_store/bin/oslo"

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
    "$source_dir/modules" "$source_dir/install.lua" "$source_dir/install.sh" \
    "$source_dir/discio.sh" "$source_dir/discio.lua" "$source_dir/discio-layout.lua" "$repo_dir/"
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
OSLO_BIN="$oslo_bin" "$oslo_bin" --norc "$repo_dir/install.lua" "$repo_dir" "$@" <&3
