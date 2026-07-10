#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

run_quiet() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@" >/dev/null
}

run bash -n install.sh generate.sh nx scripts/disko-wizard.sh scripts/disko-math.sh

if command -v shellcheck >/dev/null 2>&1; then
  run shellcheck install.sh generate.sh nx scripts/disko-wizard.sh scripts/disko-math.sh
else
  echo "warning: shellcheck not found; skipping shell lint" >&2
fi

if command -v nix-instantiate >/dev/null 2>&1; then
  run_quiet nix-instantiate --parse flake.nix
  while IFS= read -r -d '' file; do
    run_quiet nix-instantiate --parse "$file"
  done < <(find modules generated -name '*.nix' -type f -print0 2>/dev/null)
else
  echo "warning: nix-instantiate not found; skipping Nix parse checks" >&2
fi

if command -v nix >/dev/null 2>&1; then
  run_quiet "$repo_dir/generate.sh" --check-only --role laptop
  run_quiet "$repo_dir/generate.sh" --check-only --role server
else
  echo "warning: nix not found; skipping NixOS configuration eval checks" >&2
fi

run git diff --check
