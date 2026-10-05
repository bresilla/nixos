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
  [[ "$(uname -m)" == x86_64 ]] || die "This designer targets x86_64"
  command -v nix >/dev/null || die "Nix is required to load Oslo from Cachix"
  command -v curl >/dev/null || die "curl is required to resolve the current Oslo cache pin"
  oslo_work="$(mktemp -d -t nixos-oslo.XXXXXXXX)"
  trap 'rm -rf -- "$oslo_work"' EXIT
  echo "Loading the latest normal Oslo from the Termworks cache..."
  curl -fsSL https://app.cachix.org/api/v1/cache/termworks/pin > "$oslo_work/pins.json"
  oslo_store="$(OSLO_PINS_FILE="$oslo_work/pins.json" nix --extra-experimental-features nix-command eval --impure --raw --expr '
    let pins = builtins.fromJSON (builtins.readFile (builtins.getEnv "OSLO_PINS_FILE"));
        matches = builtins.filter (pin: pin.name == "oslo-x86_64-linux") pins;
    in if builtins.length matches == 1 then (builtins.head matches).lastRevision.storePath
       else throw "The normal Oslo cache pin is missing or ambiguous"')"
  [[ "$oslo_store" =~ ^/nix/store/[a-z0-9]{32}-oslo- ]] || die "Invalid normal Oslo cache path"
  if [[ ! -x "$oslo_store/bin/oslo" ]]; then
    nix_copy=(nix --extra-experimental-features "nix-command flakes" copy
      --from https://termworks.cachix.org
      --extra-trusted-public-keys 'termworks.cachix.org-1:Ty7sSVALfD5ajbcWBIdaNHcaEx3fEmVrOo+rSzy0mvE=')
    if (( EUID != 0 )) && [[ -S /nix/var/nix/daemon-socket/socket ]]; then
      command -v sudo >/dev/null || die "sudo is required to load Oslo from the signed cache"
      nix_copy=(sudo "${nix_copy[@]}")
    fi
    "${nix_copy[@]}" "$oslo_store" <&3
  fi
  oslo_bin="$oslo_store/bin/oslo"

fi
"$oslo_bin" --norc "$script_dir/discio.lua" "$script_dir" "$@" <&3
