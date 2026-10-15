#!/usr/bin/env bash
# Usage: copy-assets.sh <manifest> <source> <destination> [<source> <destination>]...
set -euo pipefail
manifest="$1"
shift
mkdir -p -- "$(dirname -- "$manifest")"
touch -- "$manifest"
copied="$(mktemp)"
trap 'rm -f -- "$copied"' EXIT

while (( $# >= 2 )); do
  source="$1" destination="$2"
  shift 2
  while IFS= read -r -d '' relative; do
    target="$destination/$relative"
    # A linked parent folder, left by the old ~/.dot setup, becomes a real one.
    parent="$destination"
    IFS=/ read -ra parts <<< "$(dirname -- "$relative")"
    for part in "${parts[@]}"; do
      [[ "$part" == . ]] && continue
      parent="$parent/$part"
      if [[ -L "$parent" ]]; then rm -f -- "$parent"; fi
    done
    mkdir -p -- "$(dirname -- "$target")"
    if [[ -d "$target" && ! -L "$target" ]]; then rm -rf -- "$target"; else rm -f -- "$target"; fi
    cp -P --preserve=mode -- "$source/$relative" "$target"
    if [[ ! -L "$target" ]]; then chmod u+w -- "$target"; fi
    printf '%s\n' "$target" >> "$copied"
  done < <(cd -- "$source" && find . \( -type f -o -type l \) -printf '%P\0')
done

# Files dropped from the repository since the last copy are removed too.
sort -u -o "$copied" -- "$copied"
sort -u -- "$manifest" | comm -23 - "$copied" | while IFS= read -r stale; do
  if [[ -f "$stale" || -L "$stale" ]]; then rm -f -- "$stale"; fi
done
cp -- "$copied" "$manifest"
