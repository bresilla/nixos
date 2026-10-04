#!/usr/bin/env bash
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo "Usage: discio.sh [--remote user@host] [output.nix]"
  echo "Design and save a machine-specific Disko layout using Oslo."
  echo "Remote mode inspects disks over SSH and saves the file locally."
  echo "This tool never partitions, formats or mounts disks."
  exit 0
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec 3<>/dev/tty || die "An interactive terminal is required"
if [[ -n "${OSLO_BIN:-}" ]]; then
  [[ -x "$OSLO_BIN" ]] || die "OSLO_BIN is not executable"
  oslo_bin="$OSLO_BIN"
else
  [[ "$(uname -m)" == x86_64 ]] || die "The pinned Oslo binary targets x86_64"
  for tool in curl tar sha256sum mktemp; do
    command -v "$tool" >/dev/null || die "$tool is missing"
  done
  discio_work="$(mktemp -d -t discio.XXXXXXXX)"
  trap 'rm -rf -- "$discio_work"' EXIT
  curl -fsSL https://github.com/termworks/oslo/releases/download/v0.7.2/oslo-linux-amd64.tar.gz -o "$discio_work/oslo.tar.gz"
  printf '%s  %s\n' '4294095c41fe8627928b0f9704e4b5ecfdabc5d185286bd9adb19fba649124a3' "$discio_work/oslo.tar.gz" | sha256sum -c -
  tar -xzf "$discio_work/oslo.tar.gz" -C "$discio_work" oslo
  oslo_bin="$discio_work/oslo"
fi
"$oslo_bin" --norc "$script_dir/discio.lua" "$script_dir" "$@" <&3
