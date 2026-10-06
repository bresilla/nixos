#!/usr/bin/env bash
set -euo pipefail
source_dir="${1:?staged checkout required}"
target_dir="${2:?installed checkout required}"
[[ -f "$source_dir/flake.nix" && -d "$target_dir" ]]

# Match tracked deletions from the staged pull. Untracked machine files and
# custom device configurations remain in place.
if command -v git >/dev/null && git -C "$target_dir" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r -d '' relative; do
    if [[ ! -e "$source_dir/$relative" && ! -L "$source_dir/$relative" ]] \
        && [[ -f "$target_dir/$relative" || -L "$target_dir/$relative" ]]; then
      rm -f -- "$target_dir/$relative"
    fi
  done < <(git -C "$target_dir" ls-files -z)
fi
cp -a --remove-destination --no-preserve=ownership -- "$source_dir/." "$target_dir/"
