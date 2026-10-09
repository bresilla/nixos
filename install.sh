#!/usr/bin/env bash
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
read_termworks() {
  CACHES_FILE="$1" CACHE_FIELD="$2" nix --extra-experimental-features nix-command eval --impure --raw --expr '
    (builtins.fromJSON (builtins.readFile (builtins.getEnv "CACHES_FILE"))).termworks.${builtins.getEnv "CACHE_FIELD"}'
}
if [[ "${1:-}" == --install ]]; then
  export NIXOS_INSTALL_ACTION=install
  shift
fi
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo "Usage: install.sh [--install] [laptop|server|phone|iot] [path/to/disko.nix]"
  echo "Installed machines update automatically using /etc/nixos settings."
  echo "A live system (or --install) starts saved/new device installation."
  echo "Choose an existing Disko file or create one through the prompts."
  exit 0
fi
[[ $# -le 2 ]] || die "Usage: install.sh [laptop|server|phone|iot] [path/to/disko.nix]"
for tool in curl nix cp mktemp find; do
  command -v "$tool" >/dev/null || die "$tool is missing; use a system with Nix installed"
done
case "$(uname -m)" in
  x86_64) oslo_system=x86_64-linux ;;
  aarch64) oslo_system=aarch64-linux ;;
  *) die "Supported architectures: x86_64 and aarch64" ;;
esac
exec 3<>/dev/tty || die "An interactive terminal is required"

install_work="$(mktemp -d -t nixos-install.XXXXXXXX)"
trap 'rm -rf -- "$install_work"' EXIT
source_dir=""
refresh_checkout=false
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  # The installed checkout updates itself; development checkouts never pull.
  if [[ "$source_dir" == /etc/nixos ]]; then refresh_checkout=true; fi
elif [[ -f /etc/nixos/flake.nix && -f /etc/nixos/user.nix ]] \
    && command -v git >/dev/null && git -C /etc/nixos rev-parse --git-dir >/dev/null 2>&1; then
  source_dir=/etc/nixos
  refresh_checkout=true
fi
repo_dir="$install_work/nixos"
if [[ -n "$source_dir" && -f "$source_dir/flake.nix" && -f "$source_dir/shared/installer/install.lua" ]]; then
  if command -v git >/dev/null && git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
    # Stage the complete checkout, including local edits, without copying
    # ignored runtime files or sockets. Keep a usable remote for future pulls.
    git clone --no-hardlinks -- "$source_dir" "$repo_dir"
    origin_url="$(git -C "$source_dir" remote get-url origin)"
    git -C "$repo_dir" remote set-url origin "$origin_url"
    while IFS= read -r -d '' relative; do
      if [[ -f "$source_dir/$relative" || -L "$source_dir/$relative" ]]; then
        mkdir -p -- "$(dirname -- "$repo_dir/$relative")"
        cp -a -- "$source_dir/$relative" "$repo_dir/$relative"
      else
        rm -f -- "$repo_dir/$relative"
      fi
    done < <(git -C "$source_dir" ls-files -z --cached --others --exclude-standard)
    if $refresh_checkout; then
      git -C "$repo_dir" pull --ff-only
    fi
  else
    mkdir -p "$repo_dir"
    cp -a "$source_dir/flake.nix" "$source_dir/shared" "$source_dir/devices" \
      "$source_dir/install.sh" "$source_dir/discio.sh" "$repo_dir/"
    [[ ! -f "$source_dir/README.md" ]] || cp -a "$source_dir/README.md" "$repo_dir/"
  fi
else
  repo_url="${NIXOS_REPO_URL:-https://github.com/bresilla/nixos.git}"
  if command -v git >/dev/null; then
    git clone --depth 1 "$repo_url" "$repo_dir"
  else
    nix --extra-experimental-features 'nix-command flakes' \
      shell nixpkgs#git --command git clone --depth 1 "$repo_url" "$repo_dir"
  fi
fi
# Resolve the newest signed normal Oslo output by its stable cache name.
echo "Loading the latest normal Oslo from the Termworks cache..."
curl -fsSL https://app.cachix.org/api/v1/cache/termworks/pin > "$install_work/pins.json"
oslo_store="$(OSLO_PINS_FILE="$install_work/pins.json" OSLO_SYSTEM="$oslo_system" nix --extra-experimental-features nix-command eval --impure --raw --expr '
  let pins = builtins.fromJSON (builtins.readFile (builtins.getEnv "OSLO_PINS_FILE"));
      matches = builtins.filter (pin: pin.name == "oslo-" + builtins.getEnv "OSLO_SYSTEM") pins;
  in if builtins.length matches == 1 then (builtins.head matches).lastRevision.storePath
     else throw "The normal Oslo cache pin is missing or ambiguous"')"
[[ "$oslo_store" =~ ^/nix/store/[a-z0-9]{32}-oslo- ]] || die "Invalid normal Oslo cache path"
if [[ ! -x "$oslo_store/bin/oslo" ]]; then
  nix_copy=(nix --extra-experimental-features "nix-command flakes" copy
    --from "$(read_termworks "$repo_dir/shared/caches.json" url)"
    --extra-trusted-public-keys "$(read_termworks "$repo_dir/shared/caches.json" key)")
  if (( EUID != 0 )) && [[ -S /nix/var/nix/daemon-socket/socket ]]; then
    command -v sudo >/dev/null || die "sudo is required to load Oslo from the signed cache"
    nix_copy=(sudo "${nix_copy[@]}")
  fi
  "${nix_copy[@]}" "$oslo_store" <&3
fi
oslo_bin="$oslo_store/bin/oslo"
bash "$repo_dir/shared/installer/cache-binaries.sh" "$repo_dir" "$oslo_system" "$install_work/pins.json"
OSLO_BIN="$oslo_bin" "$oslo_bin" --norc "$repo_dir/shared/installer/install.lua" "$repo_dir" "$@" <&3
