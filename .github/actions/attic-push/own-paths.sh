#!/usr/bin/env bash
# Print the paths in a package's closure that cache.nixos.org does not have:
# the only ones that belong in the bresilla cache.
set -euo pipefail
nix path-info -r "$1" | xargs -P 16 -I{} sh -c '
  hash=$(basename "$1" | cut -d- -f1)
  curl -fsI -o /dev/null "https://cache.nixos.org/$hash.narinfo" || echo "$1"
' _ {} | sort
