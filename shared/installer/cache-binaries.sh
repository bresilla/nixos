#!/usr/bin/env bash
set -euo pipefail
repo="${1:?repository required}"
system="${2:?architecture required}"
termworks_pins="${3:?Termworks pin response required}"
work="$(mktemp -d -t nixos-cache.XXXXXXXX)"
trap 'rm -rf -- "$work"' EXIT

echo "Loading the latest named Termworks and Paneworks binaries..."
curl -fsSL https://app.cachix.org/api/v1/cache/paneworks/pin > "$work/paneworks.json"
CACHIX_SYSTEM="$system" CACHIX_TERMWORKS_PINS="$termworks_pins" \
  CACHIX_PANEWORKS_PINS="$work/paneworks.json" \
  nix --extra-experimental-features nix-command eval --impure --json \
    --file "$repo/shared/installer/cache-binaries.nix" > "$work/resolved.json"

for cache in termworks paneworks; do
  setting() {
    CACHES_FILE="$repo/shared/caches.json" CACHIX_CACHE="$cache" CACHE_FIELD="$1" \
      nix --extra-experimental-features nix-command eval --impure --raw --expr '
        (builtins.fromJSON (builtins.readFile (builtins.getEnv "CACHES_FILE"))).${builtins.getEnv "CACHIX_CACHE"}.${builtins.getEnv "CACHE_FIELD"}'
  }
  url="$(setting url)"
  key="$(setting key)"
  # Eval must succeed before mapfile, so a missing pin cannot be skipped.
  CACHIX_RESOLVED="$work/resolved.json" CACHIX_CACHE="$cache" \
    nix --extra-experimental-features nix-command eval --impure --raw --expr '
      let resolved = builtins.fromJSON (builtins.readFile (builtins.getEnv "CACHIX_RESOLVED"));
      in builtins.concatStringsSep "\n" (builtins.attrValues resolved.${builtins.getEnv "CACHIX_CACHE"})
    ' > "$work/paths"
  mapfile -t paths < "$work/paths"
  copy=(nix-store --realise --option max-jobs 0 --option builders ''
    --option extra-substituters "$url"
    --option extra-trusted-public-keys "$key")
  if (( EUID != 0 )) && [[ -S /nix/var/nix/daemon-socket/socket ]]; then
    copy=(sudo "${copy[@]}")
  fi
  # Verify signatures and allow dependencies from the normal NixOS cache too.
  # Disable all builders: missing binaries must not trigger source builds.
  "${copy[@]}" "${paths[@]}" </dev/tty
done
cp "$work/resolved.json" "$repo/cache-binaries.json"
