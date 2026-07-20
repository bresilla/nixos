#!/usr/bin/env bash
# Download the latest static `nox` release binary and run it.
#
# Usage:
#   curl -L https://nix.bresilla.dev | bash
#   ./install.sh [nox args...]     # defaults to `nox install`
set -euo pipefail

repo="${NOX_RELEASE_REPO:-bresilla/nox}"
url="https://github.com/${repo}/releases/latest/download/nox"

dest="$(mktemp -d)/nox"
echo "Downloading nox from ${url}" >&2
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" -o "$dest"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$dest" "$url"
else
  echo "error: need curl or wget to download nox" >&2
  exit 1
fi
chmod +x "$dest"

if [[ $# -gt 0 ]]; then
  exec "$dest" "$@"
else
  exec "$dest" install
fi
