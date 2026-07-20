#!/usr/bin/env bash
# One-command NixOS install:
#
#   curl -L https://nix.bresilla.dev | bash
#   ./install.sh [nox args...]        # defaults to `nox install`
#
# 1. Fetches the static `nox` installer binary (or uses one on PATH).
# 2. Locates this config repo — the checkout you're in, or a fresh clone.
# 3. Runs the TUI wizard, which emits host/generated/system.lis.json.
#    The repo's host/lis/ translates that document into disko + system Nix at
#    evaluation time, and nox executes the installation steps against it.
set -euo pipefail

release_repo="${NOX_RELEASE_REPO:-bresilla/nox}"
config_repo_url="${NIXOS_REPO_URL:-https://github.com/bresilla/nixos.git}"

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    echo "error: need curl or wget" >&2
    exit 1
  fi
}

# ── 1. the nox binary ───────────────────────────────────────────
if [[ -n "${NOX_BIN:-}" ]]; then
  nox_bin="$NOX_BIN"
elif command -v nox >/dev/null 2>&1; then
  nox_bin="$(command -v nox)"
else
  url="https://github.com/${release_repo}/releases/latest/download/nox"
  nox_bin="$(mktemp -d)/nox"
  echo "Downloading nox from ${url}" >&2
  fetch "$url" "$nox_bin"
  chmod +x "$nox_bin"
fi

# ── 2. the config repo ──────────────────────────────────────────
find_repo_root() {
  local dir="$1"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/host/flake.nix" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

if repo_dir="$(find_repo_root "$(pwd)")"; then
  echo "Using config repo at ${repo_dir}" >&2
else
  repo_dir="$(mktemp -d)/nixos"
  echo "Cloning ${config_repo_url} to ${repo_dir}" >&2
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 "$config_repo_url" "$repo_dir"
  else
    nix --extra-experimental-features 'nix-command flakes' \
      shell nixpkgs#git -c git clone --depth 1 "$config_repo_url" "$repo_dir"
  fi
fi

# ── 3. wizard → LIS document → nix (host/lis) → installation ───
cd "$repo_dir"
if [[ $# -gt 0 ]]; then
  exec "$nox_bin" "$@"
else
  exec "$nox_bin" install
fi
