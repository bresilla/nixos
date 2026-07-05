#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./generate.sh [--role laptop|server] [--check-only]

Ensures ./specific/configuration.nix exists, then rebuilds this flake.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
role="${NIXOS_ROLE:-}"
check_only=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --role)
      role="${2:-}"
      shift 2
      ;;
    --check-only)
      check_only=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -z "$role" && -f "$repo_dir/.nixos-role" ]]; then
  role="$(<"$repo_dir/.nixos-role")"
fi

role="${role:-laptop}"
[[ "$role" == "laptop" || "$role" == "server" ]] || die "role must be laptop or server"

install -d -m 2775 "$repo_dir/specific"
if [[ ! -f "$repo_dir/specific/configuration.nix" ]]; then
  cat > "$repo_dir/specific/configuration.nix" <<'EOF'
{ ... }:

{
  # Host-specific local overrides go here.
}
EOF
  chmod 0664 "$repo_dir/specific/configuration.nix"
fi

flake_ref="path:$repo_dir#install-$role-generated"

if [[ "$check_only" -eq 1 ]]; then
  nix --extra-experimental-features 'nix-command flakes' eval --impure --no-warn-dirty "path:$repo_dir#nixosConfigurations.install-$role-generated.config.system.stateVersion" >/dev/null
  echo "check: ok"
  exit 0
fi

sudo nixos-rebuild switch --flake "$flake_ref"
