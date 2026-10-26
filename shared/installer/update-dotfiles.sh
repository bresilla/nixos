#!/usr/bin/env bash
set -euo pipefail
checkout="${1:?checkout required}"
revision="${2:?revision required}"
git=(git -c safe.directory="$checkout" -C "$checkout")

echo "Fetching dotfiles updates into $checkout."
# Root fetches without keys, so always over HTTPS whatever origin points at.
GIT_TERMINAL_PROMPT=0 "${git[@]}" fetch https://github.com/bresilla/nixos.git \
  "+$revision:refs/remotes/origin/$revision"
# Fast-forward upstream while saving and restoring tracked local preferences.
# Untracked files remain in place. Divergent commits or collisions stop here.
"${git[@]}" -c user.name='Dotfiles update' -c user.email=dotfiles@localhost \
  merge --ff-only --autostash FETCH_HEAD
if [[ -n "$("${git[@]}" diff --name-only --diff-filter=U)" ]]; then
  echo "Dotfiles updated, but local edits conflict. Resolve the files in $checkout before updating again; Git retained the autostash." >&2
  exit 1
fi
echo "Dotfiles are at $("${git[@]}" rev-parse --short HEAD); local edits preserved."
