#!/usr/bin/env bash
set -euo pipefail
user_home="${1:?user home required}"
update="${2:?checkout updater required}"
checkout="$user_home/nixos"
fetch=https://github.com/bresilla/nixos.git
push=git@github.com:bresilla/nixos.git

test -d "$user_home" || { echo "User home does not exist: $user_home" >&2; exit 1; }
# Root writes Git metadata here; the owner keeps access even if a merge stops.
trap 'test ! -d "$checkout" || chown -R -h --reference="$user_home" "$checkout"' EXIT
if [[ -e "$checkout/.git" ]]; then
  # ~/.config links here, so a checkout that cannot fast-forward stays as it is.
  bash "$update" "$checkout" main || echo "Left $checkout as it is; ~/.config links to its current files." >&2
elif [[ -e "$checkout" ]]; then
  echo "$checkout is not a Git checkout; ~/.config links into it as it is." >&2
else
  GIT_TERMINAL_PROMPT=0 git clone -- "$fetch" "$checkout"
  git -C "$checkout" remote set-url --push origin "$push"
fi
