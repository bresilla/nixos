#!/usr/bin/env bash
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo "Usage: discio.sh [--remote user@host] [output.nix]"
  echo "Design and save a machine-specific Disko layout using Oslo."
  echo "Remote mode inspects disks over SSH and saves the file locally."
  echo "This tool never partitions, formats or mounts disks."
  exit 0
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec 3<>/dev/tty || die "An interactive terminal is required"
if [[ -n "${OSLO_BIN:-}" ]]; then
  [[ -x "$OSLO_BIN" ]] || die "OSLO_BIN is not executable"
  oslo_bin="$OSLO_BIN"
else
  [[ "$(uname -m)" == x86_64 ]] || die "The pinned Oslo binary targets x86_64"
  command -v nix >/dev/null || die "Nix is required to load Oslo from Cachix"
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

fi
"$oslo_bin" --norc "$script_dir/discio.lua" "$script_dir" "$@" <&3
