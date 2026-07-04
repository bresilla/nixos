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

run bash -n install.sh scripts/disko-wizard.sh scripts/disko-math.sh agedit

if command -v shellcheck >/dev/null 2>&1; then
  run shellcheck install.sh scripts/disko-wizard.sh scripts/disko-math.sh agedit
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
  run_quiet nix --extra-experimental-features 'nix-command flakes' eval --impure --no-warn-dirty .#nixosConfigurations.install-laptop-generated.config.system.stateVersion
  run_quiet nix --extra-experimental-features 'nix-command flakes' eval --impure --no-warn-dirty .#nixosConfigurations.install-server-generated.config.system.stateVersion
else
  echo "warning: nix not found; skipping NixOS configuration eval checks" >&2
fi

if command -v node >/dev/null 2>&1; then
  run node --check .cloudflare/nix/src/index.js
  # shellcheck disable=SC2016
  run node -e '
    const fs = require("fs");
    const crypto = require("crypto");
    const config = JSON.parse(fs.readFileSync(".cloudflare/nix/wrangler.jsonc", "utf8"));
    const expected = config.vars && config.vars.INSTALLER_SHA256;
    const actual = crypto.createHash("sha256").update(fs.readFileSync("install.sh")).digest("hex");
    if (expected !== actual) {
      console.error(`INSTALLER_SHA256 mismatch: expected ${expected || "(missing)"}, actual ${actual}`);
      process.exit(1);
    }
  '
else
  echo "warning: node not found; skipping Cloudflare Worker syntax check" >&2
fi

run git diff --check
