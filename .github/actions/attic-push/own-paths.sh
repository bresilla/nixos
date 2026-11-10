#!/usr/bin/env bash
# Print the paths in a package's closure that neither cache.nixos.org nor the
# target cache has: the only ones that still need uploading.
set -euo pipefail
nix path-info -r "$1" | xargs -P 16 -I{} sh -c '
  hash=$(basename "$1" | cut -d- -f1)
  curl -fsI -m 20 -o /dev/null "https://cache.nixos.org/$hash.narinfo" && exit 0
  curl -fsI -m 20 -o /dev/null "https://cache.bresilla.com/$2/$hash.narinfo" && exit 0
  echo "$1"
' _ {} "$2" | sort
