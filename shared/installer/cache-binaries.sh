#!/usr/bin/env bash
set -euo pipefail
repo="${1:?repository required}"
system="${2:?architecture required}"
# cache.bresilla.com/-/pins, already fetched by the caller: Termworks, Paneworks and ai-nerv.
cache_pins="${3:?cache pin response required}"
work="$(mktemp -d -t nixos-cache.XXXXXXXX)"
trap 'rm -rf -- "$work"' EXIT

echo "Loading the latest named Termworks, Paneworks, Bresilla and ai-nerv binaries..."
# bresilla/devices commits its pins only after pushing; no pins stops the update.
curl -fsSL https://raw.githubusercontent.com/bresilla/devices/main/pins.json > "$work/firmware-pins.json"
# Bresilla's own packages are pinned in the repo; everything lives on cache.bresilla.com.
CACHIX_SYSTEM="$system" CACHIX_TERMWORKS_PINS="$cache_pins" \
  CACHIX_PANEWORKS_PINS="$cache_pins" BRESILLA_PINS="$repo/packages/pins.json" \
  FIRMWARE_PINS="$work/firmware-pins.json" CACHIX_AI_NERV_PINS="$cache_pins" \
  nix --extra-experimental-features nix-command eval --impure --json \
    --file "$repo/shared/installer/cache-binaries.nix" > "$work/resolved.json"

setting() {
  CACHES_FILE="$repo/shared/caches.json" CACHE_NAME="$1" CACHE_FIELD="$2" \
    nix --extra-experimental-features nix-command eval --impure --raw --expr '
      (builtins.fromJSON (builtins.readFile (builtins.getEnv "CACHES_FILE"))).${builtins.getEnv "CACHE_NAME"}.${builtins.getEnv "CACHE_FIELD"}'
}
for cache in termworks paneworks bresilla firmwares ai-nerv; do
  # Termworks, Paneworks and ai-nerv live in /bresilla; the repo's packages/ in
  # /packages; bresilla/devices' firmware in /firmwares.
  case "$cache" in
    bresilla) stores="packages" ;;
    firmwares) stores="firmwares" ;;
    *) stores="bresilla" ;;
  esac
  url="$(for store in $stores; do setting "$store" url; echo; done | paste -sd' ')"
  key="$(for store in $stores; do setting "$store" key; echo; done | paste -sd' ')"
  # Eval must succeed before mapfile, so a missing pin cannot be skipped.
  # Only the host's binaries load now; other systems' substitute when a build needs them.
  CACHIX_RESOLVED="$work/resolved.json" CACHIX_CACHE="$cache" CACHIX_SYSTEM="$system" \
    nix --extra-experimental-features nix-command eval --impure --raw --expr '
      let resolved = builtins.fromJSON (builtins.readFile (builtins.getEnv "CACHIX_RESOLVED"));
      in builtins.concatStringsSep "\n" (builtins.attrValues
        resolved.${builtins.getEnv "CACHIX_SYSTEM"}.${builtins.getEnv "CACHIX_CACHE"})
    ' > "$work/paths"
  mapfile -t paths < "$work/paths"
  (( ${#paths[@]} )) || continue
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
