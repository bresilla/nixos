#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./install.sh
  ./install.sh [--repo <git-url>] interactive
  ./install.sh [--repo <git-url>] check <host>
  ./install.sh [--repo <git-url>] key-check <host>
  ./install.sh [--repo <git-url>] preflight <role> <host> [target-host]
  ./install.sh remote <role> <host> <target-host> [nixos-anywhere args...]
  ./install.sh local  <host> <mountpoint>

Examples:
  curl -L https://nix.bresilla.dev | bash
  curl -L https://nix.bresilla.dev | bash -s -- interactive
  ./install.sh preflight laptop <host> nixos@192.168.100.163
  ./install.sh remote laptop <host> nixos@192.168.100.163
  ./install.sh local <host> /mnt
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

default_repo="https://github.com/bresilla/nixos.git"
repo_url="${NIXOS_INSTALL_REPO:-$default_repo}"

if [[ "${1:-}" == "--repo" ]]; then
  repo_url="${2:-}"
  [[ -n "$repo_url" ]] || die "--repo requires a git URL"
  shift 2
fi

mode="${1:-}"
host="${2:-}"

script_source="${BASH_SOURCE[0]-}"
if [[ -n "$script_source" && "$script_source" != "bash" && "$script_source" != "-" ]]; then
  repo_dir="$(cd -- "$(dirname -- "$script_source")" && pwd)"
else
  repo_dir="$(pwd)"
fi

if [[ ! -f "$repo_dir/flake.nix" || ! -f "$repo_dir/.sops.yaml" || ! -f "$repo_dir/secrets/key.txt" ]]; then
  command -v git >/dev/null || die "git is not in PATH and the script is not running from a repo checkout"

  checkout_dir="${NIXOS_INSTALL_DIR:-$HOME/nixos_install}"

  if [[ -d "$checkout_dir/.git" ]]; then
    if git -C "$checkout_dir" diff --quiet && git -C "$checkout_dir" diff --cached --quiet; then
      git -C "$checkout_dir" pull --ff-only >/dev/null || true
    else
      echo "using existing dirty checkout: $checkout_dir" >&2
    fi
  elif [[ -e "$checkout_dir" ]]; then
    die "$checkout_dir exists but is not a git checkout"
  else
    git clone "$repo_url" "$checkout_dir" >/dev/null
  fi

  exec "$checkout_dir/install.sh" "$@"
fi

encrypted_key=""
expected_recipient=""
BACK_TOKEN="__NIXOS_INSTALL_BACK__"
BACK_EXIT=42
INSTALL_PASSWORD_HASH_FILE="${INSTALL_PASSWORD_HASH_FILE:-}"
INSTALL_PASSWORD_HASH_TARGET="/var/lib/nixos-install/user-password.hash"
DEFAULT_DOTFILES_REPO="https://github.com/bresilla/dot.git"
DEFAULT_GUM_VERSION="v0.16.2"
YUBIKEY_PIN_CACHE_FILE=""
if [[ -d /dev/shm && -w /dev/shm ]]; then
  YUBIKEY_PIN_CACHE_FILE="/dev/shm/nixos-install-yubikey-pin.$$"
fi

cleanup_yubikey_pin_cache() {
  if [[ -n "${YUBIKEY_PIN_CACHE_FILE:-}" ]]; then
    rm -f -- "$YUBIKEY_PIN_CACHE_FILE"
  fi
}

trap cleanup_yubikey_pin_cache EXIT
trap 'cleanup_yubikey_pin_cache; echo >&2; exit 130' INT

require_host() {
  [[ -n "$host" ]] || {
    usage
    exit 2
  }
}

load_host_key_context() {
  require_host

  encrypted_key="$repo_dir/secrets/key.txt"
  expected_recipient="$(
    awk '
      $1 == "-" && $2 == "&system" { print $3; exit }
      $1 == "-" && $2 == "\\&system" { print $3; exit }
      $1 == "-" && $2 == "&system" { print $3; exit }
    ' "$repo_dir/.sops.yaml"
  )"

  [[ -f "$encrypted_key" ]] || die "missing encrypted shared system key: $encrypted_key"
  [[ -n "$expected_recipient" ]] || die "missing public recipient '&system' in $repo_dir/.sops.yaml"
}

yubikey_box() {
  local title="$1"
  local body="$2"
  local g

  if g="$(ui_gum 2>/dev/null)" && [[ -x "$g" ]]; then
    {
      printf '%s\n\n%s\n' "$title" "$body" \
        | "$g" style \
          --border rounded \
          --border-foreground 14 \
          --foreground 15 \
          --padding "1 2" \
          --width 64
      printf '\n'
    } > /dev/tty
    return 0
  fi

  {
    printf '\n== %s ==\n' "$title"
    printf '%s\n\n' "$body"
  } > /dev/tty
}

yubikey_line() {
  local label="$1"
  local value="${2:-}"
  local g

  if g="$(ui_gum 2>/dev/null)" && [[ -x "$g" ]]; then
    if [[ -n "$value" ]]; then
      printf '%s %s\n' "$label" "$value" \
        | "$g" style --foreground 14 --padding "0 1" > /dev/tty
    else
      printf '%s\n' "$label" \
        | "$g" style --foreground 14 --padding "0 1" > /dev/tty
    fi
    return 0
  fi

  if [[ -n "$value" ]]; then
    printf '%s %s\n' "$label" "$value" > /dev/tty
  else
    printf '%s\n' "$label" > /dev/tty
  fi
}

yubikey_screen() {
  if declare -F ui_main_screen >/dev/null 2>&1; then
    ui_main_screen "YubiKey" "back" "decrypt secrets"
    ui_note "Shared system secrets need the YubiKey. Enter the PIN once; later decrypts reuse it from RAM and may only need touch." > /dev/tty
  else
    ui_clear 2>/dev/null || true
    yubikey_box "YubiKey required" "Secret: shared system key
Action: plug in the YubiKey, then enter PIN or touch when prompted"
  fi
}

yubikey_pin_cache_path() {
  [[ -n "${YUBIKEY_PIN_CACHE_FILE:-}" ]] || return 1
  printf '%s\n' "$YUBIKEY_PIN_CACHE_FILE"
}

read_cached_yubikey_pin() {
  local cache_file

  cache_file="$(yubikey_pin_cache_path)" || return 1
  [[ -s "$cache_file" ]] || return 1
  cat "$cache_file"
}

write_cached_yubikey_pin() {
  local pin="$1"
  local cache_file old_umask

  cache_file="$(yubikey_pin_cache_path)" || return 0
  old_umask="$(umask)"
  umask 077
  printf '%s\n' "$pin" > "$cache_file"
  umask "$old_umask"
  chmod 0600 "$cache_file"
}

clear_cached_yubikey_pin() {
  if [[ -n "${YUBIKEY_PIN_CACHE_FILE:-}" ]]; then
    : > "$YUBIKEY_PIN_CACHE_FILE"
  fi
}

yubikey_pin_prompt() {
  local pin

  command -v script >/dev/null || return 1
  pin="$(ui_password "YubiKey PIN (Enter = normal prompt):")"
  [[ "$pin" == "$BACK_TOKEN" ]] && exit "$BACK_EXIT"
  [[ -n "$pin" ]] || return 1

  printf '%s\n' "$pin"
}

decrypt_with_yubikey_pin_pty() {
  local age_bin="$1"
  local identity_file="$2"
  local encrypted_key_file="$3"
  local decrypted_file="$4"
  local pin decrypt_cmd pty_cmd rc pin_cached=false

  if pin="$(read_cached_yubikey_pin)"; then
    pin_cached=true
    yubikey_line "YubiKey PIN:" "using cached PIN from RAM"
  else
    pin="$(yubikey_pin_prompt)" || return 1
  fi
  printf -v decrypt_cmd '%q --decrypt --identity %q %q > %q' \
    "$age_bin" "$identity_file" "$encrypted_key_file" "$decrypted_file"
  printf -v pty_cmd 'stty -echo; %s; rc=$?; stty echo; exit "$rc"' "$decrypt_cmd"

  set +e
  { sleep 0.2; printf '%s\n' "$pin"; } | script -qfec "$pty_cmd" /dev/null > /dev/tty 2>&1
  rc=$?
  set -e

  if [[ "$rc" -eq 0 && "$pin_cached" == false ]]; then
    write_cached_yubikey_pin "$pin"
  elif [[ "$rc" -ne 0 && "$pin_cached" == true ]]; then
    clear_cached_yubikey_pin
  fi
  unset pin

  return "$rc"
}

ssh_password_prompt() {
  local ssh_target="$1"
  local password

  password="$(ui_password "Password for $ssh_target:")"
  [[ "$password" == "$BACK_TOKEN" ]] && exit "$BACK_EXIT"
  [[ -n "$password" ]] || return 1

  printf '%s\n' "$password"
}

run_ssh_copy_id_with_password() {
  local ssh_target="$1"
  local pubkey="$2"
  local password tmp pass_file askpass rc

  command -v setsid >/dev/null || return 1
  password="$(ssh_password_prompt "$ssh_target")" || return 1
  tmp="$(mktemp -d)"
  pass_file="$tmp/password"
  askpass="$tmp/askpass"
  chmod 0700 "$tmp"
  printf '%s\n' "$password" > "$pass_file"
  chmod 0600 "$pass_file"
  printf '#!/usr/bin/env bash\ncat %q\n' "$pass_file" > "$askpass"
  chmod 0700 "$askpass"

  set +e
  DISPLAY="${DISPLAY:-:0}" \
    SSH_ASKPASS="$askpass" \
    SSH_ASKPASS_REQUIRE=force \
    setsid -w ssh-copy-id \
      -F /dev/null \
      -o UserKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=no \
      -i "$pubkey" \
      "$ssh_target" < /dev/null > /dev/tty 2>&1
  rc=$?
  set -e
  unset password
  rm -rf "$tmp"

  return "$rc"
}

decrypt_host_key() (
  load_host_key_context
  if ! { : > /dev/tty; } 2>/dev/null; then
    die "no interactive /dev/tty available for YubiKey PIN/touch prompt"
  fi
  command -v age-plugin-yubikey >/dev/null || die "age-plugin-yubikey is not in PATH"

  local age_bin identity_file identity_raw identity_err decrypted_file answer pcscd_state last_error
  age_bin="$(find_age)" || die "working age is not in PATH"

  identity_file="$(mktemp)"
  identity_raw="$(mktemp)"
  identity_err="$(mktemp)"
  decrypted_file="$(mktemp)"
  trap 'rm -f -- "${identity_file:-}" "${identity_raw:-}" "${identity_err:-}" "${decrypted_file:-}"' EXIT

  yubikey_screen

  while true; do
    : > "$identity_file"
    : > "$identity_raw"
    : > "$identity_err"

    pcscd_state="unknown"
    if command -v systemctl >/dev/null; then
      if systemctl --quiet is-active pcscd 2>/dev/null || systemctl --quiet is-active pcscd.socket 2>/dev/null; then
        pcscd_state="active"
      else
        pcscd_state="not active or not visible"
      fi
    fi

    yubikey_line "Checking YubiKey..."
    yubikey_line "pcscd:" "$pcscd_state"

    if age-plugin-yubikey --identity > "$identity_raw" 2> "$identity_err"; then
      if awk '/^AGE-PLUGIN-YUBIKEY-/ { print; found = 1 } END { exit found ? 0 : 1 }' "$identity_raw" > "$identity_file"; then
        break
      fi
    fi

    {
      printf 'YubiKey identity was not available.\n'
      printf 'Check: key plugged in, pcscd active, no other prompt is using it.\n'
      if [[ -s "$identity_err" ]]; then
        last_error="$(tr '\n' ' ' < "$identity_err" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
        [[ "${#last_error}" -gt 160 ]] && last_error="${last_error:0:157}..."
        printf 'last error: %s\n' "$last_error"
      fi
      printf 'Press Enter to retry, or type q then Enter to abort.\n'
    } > /dev/tty

    IFS= read -r answer < /dev/tty || exit 1
    [[ "$answer" == "q" || "$answer" == "Q" ]] && exit 1
  done

  yubikey_line "YubiKey identity:" "ok"

  while true; do
    : > "$decrypted_file"
    yubikey_line "Decrypting shared system key." "Enter PIN with gum, then touch the YubiKey if prompted."
    if decrypt_with_yubikey_pin_pty "$age_bin" "$identity_file" "$encrypted_key" "$decrypted_file"; then
      cat "$decrypted_file"
      exit 0
    fi

    yubikey_line "Using normal YubiKey prompt." "Enter PIN or touch when prompted."
    if "$age_bin" --decrypt --identity "$identity_file" "$encrypted_key" < /dev/tty > "$decrypted_file"; then
      cat "$decrypted_file"
      exit 0
    fi

    {
      printf 'Host key decrypt failed.\n'
      printf 'Press Enter to retry, or type q then Enter to abort.\n'
    } > /dev/tty
    IFS= read -r answer < /dev/tty || exit 1
    [[ "$answer" == "q" || "$answer" == "Q" ]] && exit 1
  done
)

find_age() {
  local candidate
  for candidate in /usr/bin/age /bin/age "$(command -v age 2>/dev/null || true)"; do
    [[ -n "$candidate" ]] || continue
    "$candidate" --version >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

find_age_keygen() {
  local candidate
  for candidate in /usr/bin/age-keygen /bin/age-keygen "$(command -v age-keygen 2>/dev/null || true)"; do
    [[ -n "$candidate" ]] || continue
    "$candidate" -version >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

check_host_key() (
  load_host_key_context
  command -v age-plugin-yubikey >/dev/null || die "age-plugin-yubikey is not in PATH"

  local age_keygen tmp actual_recipient
  age_keygen="$(find_age_keygen)" || die "working age-keygen is not in PATH"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  decrypt_host_key > "$tmp/key.txt" || die "could not decrypt shared system key"
  chmod 0600 "$tmp/key.txt"

  [[ -s "$tmp/key.txt" ]] || die "decrypted shared system key is empty"

  actual_recipient="$("$age_keygen" -y "$tmp/key.txt")"
  [[ "$actual_recipient" == "$expected_recipient" ]] || {
    echo "expected: $expected_recipient" >&2
    echo "actual:   $actual_recipient" >&2
    die "decrypted shared system key does not match .sops.yaml recipient '&system'"
  }

  echo "$actual_recipient"
)

run_nixos_anywhere() {
  local -a base_args
  local policy known_hosts
  policy="$(ssh_host_key_policy)"
  known_hosts="$(ssh_known_hosts_file "$policy")"
  ensure_ssh_known_hosts_parent "$known_hosts"
  base_args=(
    --ssh-option "UserKnownHostsFile=$known_hosts"
    --ssh-option "StrictHostKeyChecking=$policy"
  )
  if command -v nixos-anywhere >/dev/null; then
    nixos-anywhere "${base_args[@]}" "$@"
    return
  fi

  command -v nix >/dev/null || die "nix is not in PATH and nixos-anywhere is not installed"
  echo "nixos-anywhere is not in PATH; running it through nix."
  nix --extra-experimental-features 'nix-command flakes' run \
    github:nix-community/nixos-anywhere -- "${base_args[@]}" "$@"
}

ssh_host_key_policy() {
  local policy="${NIXOS_INSTALL_SSH_HOST_KEY_POLICY:-accept-new}"
  case "$policy" in
    accept-new | yes | no) printf '%s\n' "$policy" ;;
    strict) printf '%s\n' yes ;;
    off | insecure) printf '%s\n' no ;;
    *) die "invalid NIXOS_INSTALL_SSH_HOST_KEY_POLICY: $policy (use accept-new, yes, no, strict, off, or insecure)" ;;
  esac
}

ssh_known_hosts_file() {
  local policy="$1"
  if [[ "$policy" == "no" ]]; then
    printf '%s\n' /dev/null
    return 0
  fi
  printf '%s\n' "${NIXOS_INSTALL_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
}

ensure_ssh_known_hosts_parent() {
  local known_hosts="$1"
  local dir
  [[ "$known_hosts" != /dev/null ]] || return 0
  dir="$(dirname -- "$known_hosts")"
  mkdir -p "$dir"
  chmod 0700 "$dir" 2>/dev/null || true
}

ssh_install_base_opts() {
  local policy known_hosts
  policy="$(ssh_host_key_policy)"
  known_hosts="$(ssh_known_hosts_file "$policy")"
  ensure_ssh_known_hosts_parent "$known_hosts"
  printf '%s\n' \
    -F /dev/null \
    -o "UserKnownHostsFile=$known_hosts" \
    -o "StrictHostKeyChecking=$policy"
}

materialize_flake_source() {
  local parent_dir="$1"
  local source_dir="$parent_dir/source"

  mkdir -p "$source_dir"
  cp -a "$repo_dir/." "$source_dir/"
  rm -rf "$source_dir/.git"
  printf '%s\n' "$source_dir"
}

flake_disk_devices() {
  local flake_host="$1"
  local flake_source="$2"
  [[ "$flake_host" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid flake host name: $flake_host"
  command -v nix >/dev/null || die "nix is required to inspect Disko target disks"

  nix --extra-experimental-features 'nix-command flakes' eval \
    --raw \
    --impure \
    --no-warn-dirty \
    --no-eval-cache \
    --expr "let flake = builtins.getFlake \"path:$flake_source\"; disks = flake.nixosConfigurations.\"$flake_host\".config.disko.devices.disk; in builtins.concatStringsSep \"\\n\" (map (d: d.device) (builtins.attrValues disks))"
}

flake_bin_enabled() {
  local flake_host="$1"
  local flake_source="$2"
  [[ "$flake_host" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid flake host name: $flake_host"
  command -v nix >/dev/null || die "nix is required to inspect bin config"

  nix --extra-experimental-features 'nix-command flakes' eval \
    --raw \
    --impure \
    --no-warn-dirty \
    --no-eval-cache \
    --expr "let flake = builtins.getFlake \"path:$flake_source\"; in if flake.nixosConfigurations.\"$flake_host\".config.bresilla.programs.bin.enable then \"true\" else \"false\""
}

flake_mount_script() {
  local flake_host="$1"
  local flake_source="$2"
  [[ "$flake_host" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid flake host name: $flake_host"
  command -v nix >/dev/null || die "nix is required to build Disko mount script"

  nix --extra-experimental-features 'nix-command flakes' build \
    --no-link \
    --print-out-paths \
    --no-warn-dirty \
    "$flake_source#nixosConfigurations.$flake_host.config.system.build.mountScript"
}

ssh_install_opts_string() {
  local -a ssh_opts
  local opt
  mapfile -t ssh_opts < <(ssh_install_base_opts)
  for opt in "${ssh_opts[@]}"; do
    printf '%q ' "$opt"
  done
}

copy_closure_to_target() {
  local target="$1"
  local store_path="$2"
  local ssh_opts

  command -v nix >/dev/null || die "nix is required to copy closure to target"
  ssh_opts="$(ssh_install_opts_string)"
  NIX_SSHOPTS="$ssh_opts" nix --extra-experimental-features 'nix-command' copy \
    --to "ssh://$target" \
    "$store_path"
}

remote_run_bin_defaults() {
  local target="$1"
  local mount_script="$2"
  local quoted_mount
  local -a ssh_opts

  command -v ssh >/dev/null || die "ssh is not in PATH"
  [[ -n "$mount_script" && -e "$mount_script" ]] || die "missing Disko mount script: $mount_script"
  copy_closure_to_target "$target" "$mount_script"
  mapfile -t ssh_opts < <(ssh_install_base_opts)
  ui_info "Mounting installed system and installing default bin-managed CLI tools inside /mnt chroot."

  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$target" \
    'cat > /tmp/nixos-bin-install.sh && chmod 0700 /tmp/nixos-bin-install.sh' <<'REMOTE_BIN_INSTALL'
set -euo pipefail

mount_script="$1"
system_profile=/nix/var/nix/profiles/system
profile_link=""
system_store=""
sw_link=""
sw_store=""
live_sw=""

umount -R /mnt 2>/dev/null || true
"$mount_script"

profile_link="$(readlink /mnt/nix/var/nix/profiles/system || true)"
if [[ -z "$profile_link" ]]; then
  echo "installed system profile is not available under /mnt" >&2
  exit 1
fi

case "$profile_link" in
  /nix/store/*) system_store="$profile_link" ;;
  *) system_store="$(readlink "/mnt/nix/var/nix/profiles/$profile_link" || true)" ;;
esac

if [[ "$system_store" != /nix/store/* || ! -d "/mnt$system_store" ]]; then
  echo "installed system store path is not available under /mnt" >&2
  exit 1
fi

sw_link="$(readlink "/mnt$system_store/sw" || true)"
case "$sw_link" in
  /nix/store/*) sw_store="$sw_link" ;;
  "") sw_store="$system_store/sw" ;;
  *) sw_store="$system_store/$sw_link" ;;
esac
live_sw="/mnt$sw_store"

if [[ ! -d "$live_sw/bin" ]]; then
  echo "installed system path is not available under /mnt" >&2
  exit 1
fi

mkdir -p /mnt/tmp
cat > /mnt/tmp/nixos-bin-install-chroot.sh <<'CHROOT_BIN_INSTALL'
set -euo pipefail

  [[ -f /etc/bin/list.json ]] || {
    echo "installed-system manifest missing: /etc/bin/list.json" >&2
    exit 1
  }
  [[ -x /nix/var/nix/profiles/system/sw/bin/bin ]] || {
  echo "installed-system bin missing: /nix/var/nix/profiles/system/sw/bin/bin" >&2
  exit 1
}

/nix/var/nix/profiles/system/sw/bin/mkdir -p /var/lib/bin
/nix/var/nix/profiles/system/sw/bin/install -D -m 0644 /etc/bin/list.json /var/lib/bin/list.json
export BIN_CONFIG_FILE=/var/lib/bin/list.json
export BIN_STATE_FILE=/var/lib/bin/config.state.json
export BIN_DEFAULT_PATH=/var/lib/bin

while true; do
  set +e
  /nix/var/nix/profiles/system/sw/bin/bin --tag default ensure
  bin_status=$?
  set -e

  [[ "$bin_status" -eq 0 ]] && break

  echo "bin --tag default ensure failed with exit code $bin_status" >&2
  if [[ -x /nix/var/nix/profiles/system/sw/bin/gum ]]; then
    if /nix/var/nix/profiles/system/sw/bin/gum confirm "Retry bin defaults install?" \
      --affirmative "yes" \
      --negative "no" \
      --default \
      < /dev/tty > /dev/tty; then
      continue
    fi
  else
    printf 'Retry bin defaults install? [Y/n] ' > /dev/tty
    IFS= read -r retry_answer < /dev/tty || exit "$bin_status"
    case "$retry_answer" in
      "" | y | Y | yes | YES | Yes) continue ;;
    esac
  fi

  exit "$bin_status"
done
/nix/var/nix/profiles/system/sw/bin/find /var/lib/bin -mindepth 1 -maxdepth 1 -type f ! -name '*.json' -exec /nix/var/nix/profiles/system/sw/bin/chmod 0755 {} +
CHROOT_BIN_INSTALL
chmod 0700 /mnt/tmp/nixos-bin-install-chroot.sh
nixos-enter --root /mnt --command "$system_profile/sw/bin/bash /tmp/nixos-bin-install-chroot.sh"
REMOTE_BIN_INSTALL

  quoted_mount="$(printf '%q' "$mount_script")"
  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$target" \
    "if command -v sudo >/dev/null 2>&1; then sudo --non-interactive bash /tmp/nixos-bin-install.sh $quoted_mount; else bash /tmp/nixos-bin-install.sh $quoted_mount; fi"
}

prepare_dotfiles_checkout() {
  local repo="$1"
  local parent_dir="$2"
  local checkout_dir="$parent_dir/dotfiles"

  [[ -n "$repo" ]] || die "dotfiles repo is empty"
  command -v git >/dev/null || die "git is required to clone dotfiles"

  ui_info "Cloning dotfiles repo: $repo" >&2
  git clone --recursive "$repo" "$checkout_dir" >/dev/null
  [[ -f "$checkout_dir/run_me.sh" ]] || die "dotfiles repo must contain ./run_me.sh"
  chmod +x "$checkout_dir/run_me.sh"
  printf '%s\n' "$checkout_dir"
}

remote_run_dotfiles() {
  local target="$1"
  local mount_script="$2"
  local dotfiles_dir="$3"
  local install_user="$4"
  local quoted_mount quoted_user quoted_home
  local -a ssh_opts

  command -v ssh >/dev/null || die "ssh is not in PATH"
  command -v tar >/dev/null || die "tar is required to copy dotfiles"
  [[ -n "$mount_script" && -e "$mount_script" ]] || die "missing Disko mount script: $mount_script"
  [[ -d "$dotfiles_dir" ]] || die "missing dotfiles checkout: $dotfiles_dir"
  [[ -f "$dotfiles_dir/run_me.sh" ]] || die "dotfiles checkout missing run_me.sh"
  [[ "$install_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid install user for dotfiles: $install_user"

  copy_closure_to_target "$target" "$mount_script"
  mapfile -t ssh_opts < <(ssh_install_base_opts)

  ui_info "Mounting installed system for dotfiles."
  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$target" \
    'cat > /tmp/nixos-dotfiles-mount.sh && chmod 0700 /tmp/nixos-dotfiles-mount.sh' <<'REMOTE_DOTFILES_MOUNT'
set -euo pipefail

mount_script="$1"
umount -R /mnt 2>/dev/null || true
"$mount_script"
[[ -d /mnt/nix/var/nix/profiles ]] || {
  echo "installed system is not mounted at /mnt" >&2
  exit 1
}
mkdir -p /mnt/tmp
REMOTE_DOTFILES_MOUNT

  quoted_mount="$(printf '%q' "$mount_script")"
  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$target" \
    "if command -v sudo >/dev/null 2>&1; then sudo --non-interactive bash /tmp/nixos-dotfiles-mount.sh $quoted_mount; else bash /tmp/nixos-dotfiles-mount.sh $quoted_mount; fi"

  quoted_user="$(printf '%q' "$install_user")"
  quoted_home="$(printf '%q' "/mnt/home/$install_user/.dot")"

  ui_info "Copying dotfiles into /home/$install_user/.dot."
  (
    cd "$dotfiles_dir"
    tar -cf - .
  ) | ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$target" \
    "if command -v sudo >/dev/null 2>&1; then sudo --non-interactive sh -c 'rm -rf $quoted_home && mkdir -p $quoted_home && tar -xf - -C $quoted_home'; else sh -c 'rm -rf $quoted_home && mkdir -p $quoted_home && tar -xf - -C $quoted_home'; fi"

  ui_info "Running dotfiles ./run_me.sh inside installed system chroot."
  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$target" \
    'cat > /tmp/nixos-dotfiles-run.sh && chmod 0700 /tmp/nixos-dotfiles-run.sh' <<'REMOTE_DOTFILES_RUN'
set -euo pipefail

install_user="$1"
cat > /mnt/tmp/nixos-dotfiles-run-chroot.sh <<'CHROOT_DOTFILES_RUN'
set -euo pipefail

install_user="$1"
home_dir="/home/$install_user"
dot_dir="$home_dir/.dot"

[[ -d "$dot_dir" ]] || {
  echo "dotfiles directory missing: $dot_dir" >&2
  exit 1
}
[[ -f "$dot_dir/run_me.sh" ]] || {
  echo "dotfiles run script missing: $dot_dir/run_me.sh" >&2
  exit 1
}

chmod +x "$dot_dir/run_me.sh"
cd "$dot_dir"
sudo_shim_dir=/tmp/nixos-install-sudo-shim
mkdir -p "$sudo_shim_dir"
cat > "$sudo_shim_dir/sudo" <<'SUDO_SHIM'
#!/usr/bin/env bash
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -n | --non-interactive | -E | -H) shift ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
exec "$@"
SUDO_SHIM
chmod 0755 "$sudo_shim_dir/sudo"
set +e
env PATH="$sudo_shim_dir:$PATH" HOME="$home_dir" USER="$install_user" LOGNAME="$install_user" bash ./run_me.sh --skip-bin
run_me_status=$?
set -e
if [[ "$run_me_status" -ne 0 ]]; then
  echo "dotfiles run_me.sh failed with exit code $run_me_status" >&2
  exit "$run_me_status"
fi

primary_group="$(id -gn "$install_user" 2>/dev/null || printf users)"
chown -R "$install_user:$primary_group" "$dot_dir"
for path in "$home_dir/.local" "$home_dir/.config" "$home_dir/.zshenv" "$home_dir/.profile" "$home_dir/.winitrc"; do
  if [[ -e "$path" || -L "$path" ]]; then
    chown -R -h "$install_user:$primary_group" "$path" || true
  fi
done
CHROOT_DOTFILES_RUN
chmod 0700 /mnt/tmp/nixos-dotfiles-run-chroot.sh
nixos-enter --root /mnt --command "/nix/var/nix/profiles/system/sw/bin/bash /tmp/nixos-dotfiles-run-chroot.sh $install_user"
REMOTE_DOTFILES_RUN

  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$target" \
    "if command -v sudo >/dev/null 2>&1; then sudo --non-interactive bash /tmp/nixos-dotfiles-run.sh $quoted_user; else bash /tmp/nixos-dotfiles-run.sh $quoted_user; fi"
  ui_success "dotfiles: ok"
}

local_run_dotfiles() {
  local mountpoint="$1"
  local install_user="$2"
  local repo="$3"
  local tmp dotfiles_dir home_dir

  [[ "$install_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid install user for dotfiles: $install_user"
  [[ -d "$mountpoint" ]] || die "mountpoint does not exist: $mountpoint"
  [[ -d "$mountpoint/nix/var/nix/profiles" ]] || die "installed system is not mounted at $mountpoint"
  command -v nixos-enter >/dev/null || die "nixos-enter is required to run dotfiles in a local chroot"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  dotfiles_dir="$(prepare_dotfiles_checkout "$repo" "$tmp")"
  home_dir="$mountpoint/home/$install_user"

  ui_info "Copying dotfiles into $home_dir/.dot."
  rm -rf "$home_dir/.dot"
  mkdir -p "$home_dir/.dot"
  (
    cd "$dotfiles_dir"
    tar -cf - .
  ) | tar -xf - -C "$home_dir/.dot"

  mkdir -p "$mountpoint/tmp"
  cat > "$mountpoint/tmp/nixos-dotfiles-run-chroot.sh" <<'CHROOT_DOTFILES_RUN'
set -euo pipefail

install_user="$1"
home_dir="/home/$install_user"
dot_dir="$home_dir/.dot"
chmod +x "$dot_dir/run_me.sh"
cd "$dot_dir"
sudo_shim_dir=/tmp/nixos-install-sudo-shim
mkdir -p "$sudo_shim_dir"
cat > "$sudo_shim_dir/sudo" <<'SUDO_SHIM'
#!/usr/bin/env bash
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -n | --non-interactive | -E | -H) shift ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
exec "$@"
SUDO_SHIM
chmod 0755 "$sudo_shim_dir/sudo"
set +e
env PATH="$sudo_shim_dir:$PATH" HOME="$home_dir" USER="$install_user" LOGNAME="$install_user" bash ./run_me.sh --skip-bin
run_me_status=$?
set -e
if [[ "$run_me_status" -ne 0 ]]; then
  echo "dotfiles run_me.sh failed with exit code $run_me_status" >&2
  exit "$run_me_status"
fi
primary_group="$(id -gn "$install_user" 2>/dev/null || printf users)"
chown -R "$install_user:$primary_group" "$dot_dir"
for path in "$home_dir/.local" "$home_dir/.config" "$home_dir/.zshenv" "$home_dir/.profile" "$home_dir/.winitrc"; do
  if [[ -e "$path" || -L "$path" ]]; then
    chown -R -h "$install_user:$primary_group" "$path" || true
  fi
done
CHROOT_DOTFILES_RUN
  chmod 0700 "$mountpoint/tmp/nixos-dotfiles-run-chroot.sh"
  nixos-enter --root "$mountpoint" --command "/nix/var/nix/profiles/system/sw/bin/bash /tmp/nixos-dotfiles-run-chroot.sh $install_user"
}

remote_reboot_after_install() {
  local target="$1"
  local -a ssh_opts

  command -v ssh >/dev/null || die "ssh is not in PATH"
  mapfile -t ssh_opts < <(ssh_install_base_opts)
  ui_info "Rebooting target."
  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$target" \
    'cat > /tmp/nixos-install-reboot.sh && chmod 0700 /tmp/nixos-install-reboot.sh' <<'REMOTE_REBOOT'
set -euo pipefail

sync
nohup sh -c 'sleep 3; if command -v systemctl >/dev/null 2>&1; then systemctl reboot --force; else reboot; fi' >/dev/null 2>&1 &
REMOTE_REBOOT

  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$target" \
    'if command -v sudo >/dev/null 2>&1; then sudo --non-interactive bash /tmp/nixos-install-reboot.sh; else bash /tmp/nixos-install-reboot.sh; fi'
}

ssh_key_auth_ok() {
  local ssh_target="$1"
  local -a ssh_opts
  mapfile -t ssh_opts < <(ssh_install_base_opts)
  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    "$ssh_target" true >/dev/null 2>&1
}

forget_known_host_for_target() {
  local ssh_target="$1"
  local host="${ssh_target#*@}"
  local policy known_hosts

  host="${host%%:*}"
  policy="$(ssh_host_key_policy)"
  known_hosts="$(ssh_known_hosts_file "$policy")"
  [[ "$known_hosts" != /dev/null ]] || return 1
  [[ -f "$known_hosts" ]] || return 1
  command -v ssh-keygen >/dev/null || return 1

  ui_warn "Removing stale SSH host key for $host from $known_hosts."
  ssh-keygen -R "$host" -f "$known_hosts" >/dev/null 2>&1
}

choose_ssh_public_key() {
  local keys=()
  local key selected

  if [[ -n "${NIXOS_INSTALL_SSH_PUBKEY:-}" ]]; then
    [[ -f "$NIXOS_INSTALL_SSH_PUBKEY" ]] || die "NIXOS_INSTALL_SSH_PUBKEY does not exist: $NIXOS_INSTALL_SSH_PUBKEY"
    printf '%s\n' "$NIXOS_INSTALL_SSH_PUBKEY"
    return 0
  fi

  for key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME"/.ssh/*.pub; do
    [[ -f "$key" ]] || continue
    [[ "$(basename "$key")" == known_hosts* ]] && continue
    keys+=("$key")
  done

  [[ "${#keys[@]}" -gt 0 ]] || die "no SSH public key found in $HOME/.ssh; create one with ssh-keygen first"

  if [[ "${#keys[@]}" -eq 1 ]]; then
    printf '%s\n' "${keys[0]}"
    return 0
  fi

  selected="$(ui_choose "public key to install on target" "${keys[@]}")"
  [[ "$selected" == "$BACK_TOKEN" ]] && die "cancelled"
  printf '%s\n' "$selected"
}

ensure_remote_ssh_access() {
  local ssh_target="$1"
  local pubkey

  command -v ssh >/dev/null || die "ssh is not in PATH"
  if ssh_key_auth_ok "$ssh_target"; then
    return 0
  fi
  if forget_known_host_for_target "$ssh_target" && ssh_key_auth_ok "$ssh_target"; then
    ui_success "ssh key auth: ok ($ssh_target)"
    return 0
  fi

  command -v ssh-copy-id >/dev/null || die "SSH key auth failed and ssh-copy-id is not installed"
  pubkey="$(choose_ssh_public_key)"

  ui_warn "SSH key auth failed for $ssh_target."
  ui_info "I can run ssh-copy-id now. It will install:"
  ui_info "  $pubkey"
  ui_confirm "Install this SSH public key on $ssh_target?" || die "cancelled"

  if ! run_ssh_copy_id_with_password "$ssh_target" "$pubkey"; then
    ui_warn "gum password prompt failed or was skipped; falling back to ssh-copy-id prompt."
    ssh-copy-id \
      -F /dev/null \
      -o UserKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=no \
      -i "$pubkey" \
      "$ssh_target" < /dev/tty
  fi

  ssh_key_auth_ok "$ssh_target" || die "SSH key auth still failed after ssh-copy-id"
  ui_success "ssh key auth: ok ($ssh_target)"
}

remote_prepare_disk() {
  local target="$1"
  local disk="$2"
  local quoted_disk
  local -a ssh_opts

  [[ "$disk" == /dev/* ]] || die "refusing to prepare non-/dev disk path: $disk"
  command -v ssh >/dev/null || die "ssh is not in PATH"
  mapfile -t ssh_opts < <(ssh_install_base_opts)
  quoted_disk="$(printf '%q' "$disk")"

  ui_info "preparing target disk: $disk"
  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$target" \
    "if command -v sudo >/dev/null 2>&1; then sudo --non-interactive bash -s -- $quoted_disk; else bash -s -- $quoted_disk; fi" <<'REMOTE_DISK_PREP'
set -euo pipefail

disk="$1"
case "$disk" in
  /dev/*) ;;
  *) echo "refusing non-/dev disk path: $disk" >&2; exit 2 ;;
esac

umount -R /mnt 2>/dev/null || true
swapoff --all 2>/dev/null || true

if command -v vgchange >/dev/null 2>&1; then
  vgchange -an 2>/dev/null || true
fi

if command -v lsblk >/dev/null 2>&1; then
  while IFS= read -r dev; do
    wipefs --all --force "$dev" 2>/dev/null || true
  done < <(lsblk -lnpo NAME "$disk" 2>/dev/null | tac)
fi

wipefs --all --force "$disk" 2>/dev/null || true

if command -v blkdiscard >/dev/null 2>&1 && blkdiscard -f "$disk" 2>/dev/null; then
  echo "target disk prepared with blkdiscard: $disk"
else
  echo "blkdiscard unavailable; zeroing first 4 GiB of $disk"
  dd if=/dev/zero of="$disk" bs=16M count=256 conv=fsync status=none 2>/dev/null || true
fi

blockdev --rereadpt "$disk" 2>/dev/null || true
udevadm settle 2>/dev/null || true
REMOTE_DISK_PREP
}

remote_prepare_install_disks() {
  local flake_host="$1"
  local target="$2"
  local flake_source="$3"
  local generated_host="$4"
  local disk disks

  disks="$(flake_disk_devices "$flake_host" "$flake_source")"
  [[ -n "$disks" ]] || die "could not determine Disko target disks for $flake_host"

  confirm_remote_disk_wipe "$target" "$generated_host" "$disks"

  ui_info "Cleaning target disk signatures before Disko."
  while IFS= read -r disk; do
    [[ -n "$disk" ]] || continue
    remote_prepare_disk "$target" "$disk"
  done <<< "$disks"
}

confirm_remote_disk_wipe() {
  local target="$1"
  local _generated_host="$2"
  local disks="$3"
  local disk disk_list=""

  if [[ "${NIXOS_INSTALL_ASSUME_YES:-}" == "1" ]]; then
    ui_warn "NIXOS_INSTALL_ASSUME_YES=1 set; skipping disk wipe confirmation."
    return 0
  fi

  while IFS= read -r disk; do
    [[ -n "$disk" ]] || continue
    disk_list+="$disk "
  done <<< "$disks"

  ui_warn "This will destroy all data on: $disk_list"
  ui_confirm "Wipe target disks on $target and continue with install?" || die "cancelled"
}

write_generated_host_config() {
  local role="$1"
  local generated_host="$2"
  local generated_dir="$repo_dir/generated"
  local generated_host_file="$generated_dir/host.nix"

  [[ "$generated_host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
    || die "invalid hostname: $generated_host"

  install -d -m 0755 "$generated_dir"
  cat > "$generated_host_file" <<EOF
{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  networking.hostName = "$generated_host";

  bresilla.features.system.architecture = "unknown";
  bresilla.features.system.cpuVendor = "unknown";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi = {
    canTouchEfiVariables = true;
    efiSysMountPoint = "/boot/efi";
  };
}
EOF
}

write_generated_user_config() {
  local install_user="$1"
  local password_hash_file="${2:-}"
  local generated_dir="$repo_dir/generated"
  local generated_user_file="$generated_dir/user.nix"

  install -d -m 0755 "$generated_dir"
  if [[ -n "$password_hash_file" ]]; then
    cat > "$generated_user_file" <<EOF
{ ... }:

{
  bresilla.user.name = "$install_user";
  bresilla.user.hashedPasswordFile = "$INSTALL_PASSWORD_HASH_TARGET";
}
EOF
  else
    cat > "$generated_user_file" <<EOF
{ ... }:

{
  bresilla.user.name = "$install_user";
  bresilla.user.hashedPasswordFile = null;
}
EOF
  fi
}

write_generated_bin_config() {
  local enable_bin="$1"
  local generated_dir="$repo_dir/generated"
  local generated_bin_file="$generated_dir/bin.nix"

  install -d -m 0755 "$generated_dir"
  cat > "$generated_bin_file" <<EOF
{ ... }:

{
  bresilla.programs.bin.enable = $enable_bin;
}
EOF
}

hash_password_prompt() {
  local install_user="$1"
  local pass1 pass2 hash_file

  command -v mkpasswd >/dev/null || die "mkpasswd is required to set an initial password"

  while true; do
    pass1="$(ui_password "password for $install_user:")"
    [[ "$pass1" == "$BACK_TOKEN" ]] && {
      printf '%s\n' "$BACK_TOKEN"
      return 0
    }
    pass2="$(ui_password "repeat password:")"
    [[ "$pass2" == "$BACK_TOKEN" ]] && {
      printf '%s\n' "$BACK_TOKEN"
      return 0
    }
    if [[ "$pass1" == "$pass2" ]]; then
      break
    fi
    ui_warn "Passwords did not match."
  done

  hash_file="$(mktemp)"
  chmod 0600 "$hash_file"
  printf '%s\n' "$pass1" | mkpasswd -m yescrypt -s > "$hash_file"
  pass1=""
  pass2=""
  printf '%s\n' "$hash_file"
}

preflight_generated_install() {
  local role="$1"
  local generated_host="$2"
  local target="${3:-}"
  local flake_host="install-${role}-generated"
  local tmp flake_source

  host="$generated_host"

  ui_box "Preflight checks" \
    "repo: $repo_dir
hostname: $generated_host
secrets: shared system secrets
machine type: $role
flake: $flake_host"

  [[ -f "$repo_dir/generated/disko.nix" ]] || die "missing generated Disko file: $repo_dir/generated/disko.nix"
  [[ -f "$repo_dir/generated/host.nix" ]] || die "missing generated host file: $repo_dir/generated/host.nix"
  [[ -f "$repo_dir/generated/bin.nix" ]] || die "missing generated bin file: $repo_dir/generated/bin.nix"
  [[ -f "$repo_dir/secrets/system.yaml" ]] || die "missing shared system secrets file: $repo_dir/secrets/system.yaml"
  [[ -f "$repo_dir/secrets/key.txt" ]] || die "missing encrypted shared system key: $repo_dir/secrets/key.txt"
  ui_success "repo files: ok"

  ui_info "YubiKey check: plug in the key, then follow PIN/touch prompts."
  actual_recipient="$(check_host_key)"
  ui_success "shared system key: ok"

  command -v nix >/dev/null || die "nix is not in PATH"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  flake_source="$(materialize_flake_source "$tmp")"

  nix --extra-experimental-features 'nix-command flakes' --no-warn-dirty eval \
    "$flake_source#nixosConfigurations.$flake_host.config.sops.age.keyFile" >/dev/null
  nix --extra-experimental-features 'nix-command flakes' --no-warn-dirty eval \
    "$flake_source#nixosConfigurations.$flake_host.config.sops.secrets.\"netbird/setup_key\".path" >/dev/null
  ui_success "nix eval: ok"

  if [[ -n "$target" ]]; then
    ensure_remote_ssh_access "$target"
    ui_success "ssh: ok ($target)"
  fi

  ui_success "preflight: ok"
}

remote_generated_install() {
  local role="$1"
  local generated_host="$2"
  local target="$3"
  local flake_host="install-${role}-generated"
  local flake_source extra_dir bin_enabled mount_script dotfiles_repo dotfiles_dir install_user
  local -a nixos_anywhere_args
  shift 3

  dotfiles_repo="${DOTFILES_REPO:-}"
  install_user="${INSTALL_USER:-bresilla}"
  host="$generated_host"
  [[ "$install_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid install user: $install_user"

  command -v sops >/dev/null || die "sops is not in PATH"
  command -v age-plugin-yubikey >/dev/null || die "age-plugin-yubikey is not in PATH"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  extra_dir="$tmp/extra"
  flake_source="$(materialize_flake_source "$tmp")"

  install -d -m 0755 "$extra_dir/var/lib/sops-nix"
  decrypt_host_key > "$extra_dir/var/lib/sops-nix/key.txt"
  chmod 0600 "$extra_dir/var/lib/sops-nix/key.txt"
  if [[ -n "$INSTALL_PASSWORD_HASH_FILE" ]]; then
    install -d -m 0755 "$extra_dir/var/lib/nixos-install"
    install -m 0600 "$INSTALL_PASSWORD_HASH_FILE" "$extra_dir$INSTALL_PASSWORD_HASH_TARGET"
  fi
  if [[ -n "$dotfiles_repo" ]]; then
    dotfiles_dir="$(prepare_dotfiles_checkout "$dotfiles_repo" "$tmp")"
  fi

  ensure_remote_ssh_access "$target"
  remote_prepare_install_disks "$flake_host" "$target" "$flake_source" "$generated_host"

  bin_enabled="$(flake_bin_enabled "$flake_host" "$flake_source")"
  nixos_anywhere_args=(
    --extra-files "$extra_dir"
    --flake "$flake_source#$flake_host"
  )
  if [[ "$bin_enabled" == "true" ]]; then
    nixos_anywhere_args+=(--phases "kexec,disko,install")
  fi
  if [[ -n "$dotfiles_repo" && "$bin_enabled" != "true" ]]; then
    nixos_anywhere_args+=(--phases "kexec,disko,install")
  fi

  run_nixos_anywhere \
    "${nixos_anywhere_args[@]}" \
    "$@" \
    "$target"

  if [[ "$bin_enabled" == "true" ]]; then
    mount_script="$(flake_mount_script "$flake_host" "$flake_source")"
    remote_run_bin_defaults "$target" "$mount_script"
  fi
  if [[ -n "$dotfiles_repo" ]]; then
    [[ -n "${mount_script:-}" ]] || mount_script="$(flake_mount_script "$flake_host" "$flake_source")"
    remote_run_dotfiles "$target" "$mount_script" "$dotfiles_dir" "$install_user"
  fi
  remote_reboot_after_install "$target"
}

find_gum() {
  if [[ -n "${GUM_BIN:-}" && -x "${GUM_BIN:-}" ]]; then
    printf '%s\n' "$GUM_BIN"
    return 0
  fi

  command -v gum 2>/dev/null && return 0

  if [[ -x /tmp/nixos-install-tools/gum ]]; then
    printf '%s\n' /tmp/nixos-install-tools/gum
    return 0
  fi

  return 1
}

download_gum() {
  local os arch asset_pattern api url tmp gum_bin gum_version
  os="$(uname -s)"
  arch="$(uname -m)"
  gum_version="${NIXOS_INSTALL_GUM_VERSION:-$DEFAULT_GUM_VERSION}"

  case "$os:$arch" in
    Linux:x86_64) asset_pattern='Linux_x86_64.tar.gz' ;;
    Linux:aarch64 | Linux:arm64) asset_pattern='Linux_arm64.tar.gz' ;;
    *) die "automatic gum download is not supported on $os/$arch; install gum manually" ;;
  esac

  command -v curl >/dev/null || die "curl is required to download gum"
  command -v tar >/dev/null || die "tar is required to unpack gum"

  api="$(curl -fsSL "https://api.github.com/repos/charmbracelet/gum/releases/tags/$gum_version")"
  url="$(
    printf '%s\n' "$api" \
      | sed -nE 's/.*"browser_download_url": "([^"]*'"$asset_pattern"')".*/\1/p' \
      | head -n 1
  )"

  [[ -n "$url" ]] || die "could not find gum release asset matching $asset_pattern"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL "$url" -o "$tmp/gum.tar.gz"
  if [[ -n "${NIXOS_INSTALL_GUM_SHA256:-}" ]]; then
    command -v sha256sum >/dev/null || die "sha256sum is required when NIXOS_INSTALL_GUM_SHA256 is set"
    printf '%s  %s\n' "$NIXOS_INSTALL_GUM_SHA256" "$tmp/gum.tar.gz" | sha256sum --check >/dev/null
  fi
  tar -xzf "$tmp/gum.tar.gz" -C "$tmp"

  gum_bin="$(find "$tmp" -type f -name gum -perm -111 | head -n 1)"
  [[ -n "$gum_bin" ]] || die "gum archive did not contain an executable gum binary"

  install -d -m 0755 /tmp/nixos-install-tools
  install -m 0755 "$gum_bin" /tmp/nixos-install-tools/gum
  printf '%s\n' /tmp/nixos-install-tools/gum
}

ensure_gum() {
  find_gum || download_gum
}

ui_gum() {
  if [[ -n "${gum:-}" ]]; then
    printf '%s\n' "$gum"
    return 0
  fi
  ensure_gum
}

ui_width() {
  local cols
  cols=""
  if [[ -r /dev/tty ]] && command -v stty >/dev/null; then
    cols="$(stty size 2>/dev/null < /dev/tty | awk '{ print $2 }')"
  fi
  if [[ -z "$cols" ]]; then
    cols="${COLUMNS:-}"
  fi
  if [[ -z "$cols" ]] && command -v tput >/dev/null; then
    cols="$(tput cols 2>/dev/null || true)"
  fi
  cols="${cols:-80}"
  [[ "$cols" -lt 52 ]] && cols=52
  [[ "$cols" -gt 54 ]] && cols=$((cols - 2))
  printf '%s\n' "$cols"
}

ui_title() {
  local title="$1"
  local prev="${2:-}"
  local next="${3:-}"
  local width inner line blank text_width left right row title_pos title_len right_pos max_left_len max_right_len before after
  width="$(ui_width)"
  inner=$((width - 2))
  text_width=$((inner - 2))
  line="$(ui_repeat_char "$inner" "─")"
  blank="$(printf '%*s' "$inner" '')"
  left="Esc: ${prev:-back}"
  right="Next: ${next:-continue}"
  title_len="${#title}"
  if [[ "$title_len" -gt "$text_width" ]]; then
    title="${title:0:text_width}"
    title_len="${#title}"
  fi
  title_pos=$(((text_width - title_len) / 2))

  max_left_len=$((title_pos - 1))
  [[ "$max_left_len" -lt 0 ]] && max_left_len=0
  if [[ "${#left}" -gt "$max_left_len" ]]; then
    left="${left:0:max_left_len}"
  fi

  max_right_len=$((text_width - title_pos - title_len - 1))
  [[ "$max_right_len" -lt 0 ]] && max_right_len=0
  if [[ "${#right}" -gt "$max_right_len" ]]; then
    right="${right:0:max_right_len}"
  fi
  right_pos=$((text_width - ${#right}))
  row="$(printf '%*s' "$text_width" '')"
  row="${left}${row:${#left}}"
  row="${row:0:right_pos}${right}${row:right_pos+${#right}}"
  before="${row:0:title_pos}"
  after="${row:title_pos+title_len}"

  printf '\n\033[96m╭%s╮\033[0m\n' "$line"
  printf '\033[96m│%s│\033[0m\n' "$blank"
  printf '\033[96m│\033[0m \033[90m%s\033[0m\033[97;1m%s\033[0m\033[90m%s\033[0m \033[96m│\033[0m\n' "$before" "$title" "$after"
  printf '\033[96m│%s│\033[0m\n' "$blank"
  printf '\033[96m╰%s╯\033[0m\n\n' "$line"
}

ui_repeat_char() {
  local count="$1"
  local char="$2"
  local out=""
  local i
  for ((i = 0; i < count; i++)); do
    out+="$char"
  done
  printf '%s\n' "$out"
}

ui_clear() {
  if [[ -w /dev/tty ]]; then
    printf '\033[H\033[2J\033[3J' > /dev/tty
  else
    printf '\033[H\033[2J\033[3J'
  fi
}

ui_main_screen() {
  local section="${1:-}"
  local prev="${2:-}"
  local next="${3:-}"
  ui_clear
  {
    ui_title "NixOS installer" "$prev" "$next"
    ui_note "Esc goes back to the previous step. Select target, generate a Disko layout, choose laptop/server, then run the install."
    [[ -n "$section" ]] && ui_section "$section"
  } > /dev/tty
}

ui_section() {
  printf '\n\033[96;1m%s\033[0m\n\n' "$1"
}

ui_note() {
  printf '\033[90m%s\033[0m\n\n' "$1"
}

ui_success() {
  printf '\033[92;1m%s\033[0m\n' "$1"
}

ui_info() {
  printf '\033[93m%s\033[0m\n' "$1"
}

ui_dim() {
  printf '\033[90m%s\033[0m\n' "$1"
}

ui_warn() {
  printf '\033[93;1m%s\033[0m\n' "$1"
}

ui_box() {
  local title="$1"
  local body="$2"
  local width inner line blank text_width row
  width="$(ui_width)"
  inner=$((width - 2))
  text_width=$((inner - 2))
  line="$(ui_repeat_char "$inner" "─")"
  blank="$(printf '%*s' "$inner" '')"
  printf '\n\033[93m╭%s╮\033[0m\n' "$line"
  printf '\033[93m│%s│\033[0m\n' "$blank"
  printf '\033[93m│\033[0m  \033[97;1m%-*s\033[0m\033[93m│\033[0m\n' "$text_width" "$title"
  printf '\033[93m│%s│\033[0m\n' "$blank"
  while IFS= read -r row; do
    printf '\033[93m│\033[0m  \033[97m%-*s\033[0m\033[93m│\033[0m\n' "$text_width" "$row"
  done <<< "$body"
  printf '\033[93m│%s│\033[0m\n' "$blank"
  printf '\033[93m╰%s╯\033[0m\n\n' "$line"
}

show_install_summary() {
  local title="$1"
  local config="$2"
  local install_host="$3"
  local profile="${4:-}"
  local destination="${5:-}"
  local summary_file="$repo_dir/generated/install-summary.txt"
  local tmp

  tmp="$(mktemp)"
  {
    echo "$title"
    echo
    echo "Install"
    echo "  target: $scope"
    [[ -n "$destination" ]] && echo "  destination: $destination"
    echo "  system config: $config"
    echo "  hostname: $install_host"
    echo "  secrets: shared system secrets"
    echo "  user: ${install_user:-bresilla}"
    echo "  bin defaults: ${enable_bin:-false}"
    if [[ -n "${dotfiles_repo:-}" ]]; then
      echo "  dotfiles repo: $dotfiles_repo"
    else
      echo "  dotfiles repo: skipped"
    fi
    if [[ -n "$INSTALL_PASSWORD_HASH_FILE" ]]; then
      echo "  password: set"
    else
      echo "  password: not set"
    fi
    [[ -n "$profile" ]] && echo "  machine type: $profile"
    echo

    if [[ -f "$summary_file" ]]; then
      cat "$summary_file"
    else
      echo "Disk layout"
      echo "  summary file missing: $summary_file"
      echo "  check the selected Disko config before continuing"
    fi
  } > "$tmp"

  ui_box "$title" "$(sed '1d' "$tmp")"

  rm -f "$tmp"
}

ui_choose() {
  local header="$1"
  local g out rc tmp_out
  shift
  g="$(ui_gum)"
  tmp_out="$(mktemp)"
  set +e
  "$g" choose \
    --header "$header" \
    --height 8 \
    --cursor "> " \
    --cursor-prefix "> " \
    --selected-prefix "* " \
    --unselected-prefix "  " \
    --header.foreground 14 \
    --cursor.foreground 0 \
    --cursor.background 1 \
    --selected.foreground 0 \
    --selected.background 1 \
    --item.foreground 15 \
    --padding "1 2" \
    "$@" > "$tmp_out"
  rc=$?
  set -e
  [[ "$rc" -eq 130 ]] && exit 130
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp_out"
    printf '%s\n' "$BACK_TOKEN"
    return 0
  fi
  out="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  printf '%s\n' "$out"
}

ui_input() {
  local prompt="$1"
  local placeholder="${2:-}"
  local value="${3:-}"
  local g out rc tmp_out
  g="$(ui_gum)"
  tmp_out="$(mktemp)"
  set +e
  "$g" input \
    --prompt "$prompt " \
    --placeholder "$placeholder" \
    --value "$value" \
    --width 72 \
    --prompt.foreground 14 \
    --placeholder.foreground 8 \
    --cursor.foreground 13 \
    --padding "1 2" > "$tmp_out"
  rc=$?
  set -e
  [[ "$rc" -eq 130 ]] && exit 130
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp_out"
    printf '%s\n' "$BACK_TOKEN"
    return 0
  fi
  out="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  printf '%s\n' "$out"
}

ui_password() {
  local prompt="$1"
  local g out rc tmp_out
  g="$(ui_gum)"
  tmp_out="$(mktemp)"
  set +e
  "$g" input \
    --password \
    --prompt "$prompt " \
    --width 72 \
    --prompt.foreground 14 \
    --cursor.foreground 13 \
    --padding "1 2" > "$tmp_out"
  rc=$?
  set -e
  [[ "$rc" -eq 130 ]] && exit 130
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp_out"
    printf '%s\n' "$BACK_TOKEN"
    return 0
  fi
  out="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  printf '%s\n' "$out"
}

ui_confirm() {
  local g rc
  g="$(ui_gum)"
  set +e
  "$g" confirm "$1" \
    --affirmative "yes" \
    --negative "no" \
    --prompt.foreground 14 \
    --selected.foreground 0 \
    --selected.background 10 \
    --unselected.foreground 15 \
    --unselected.background 0 \
    --padding "1 2"
  rc=$?
  set -e
  [[ "$rc" -eq 130 ]] && exit 130
  return "$rc"
}

run_disko_wizard() {
  "$repo_dir/scripts/disko-wizard.sh" "$@"
}

interactive_main() {
  local gum scope target machine_type install_hostname mountpoint step rc install_user set_password password_hash enable_bin dotfiles_repo
  gum="$(ensure_gum)"

  step="target"
  while true; do
    case "$step" in
      target)
        ui_main_screen "Target" "cancel" "disk layout"
        scope="$(ui_choose "where should the installer run?" "LOCAL" "REMOTE")"
        [[ "$scope" == "$BACK_TOKEN" ]] && die "cancelled"
        [[ -n "$scope" ]] || die "no target selected"
        target=""
        step="configure"
        [[ "$scope" == "REMOTE" ]] && step="remote-target"
        ;;

      remote-target)
        ui_main_screen "Remote Target" "target" "disk layout"
        target="$(ui_input "ssh target:" "nixos@192.168.100.163" "${target:-}")"
        [[ "$target" == "$BACK_TOKEN" ]] && {
          step="target"
          continue
        }
        [[ -n "$target" ]] || die "ssh target is required"
        step="configure"
        ;;

      configure)
        ui_main_screen "Disk Layout" "target" "system profile"
        set +e
        run_disko_wizard "$scope" "${target:-}"
        rc=$?
        set -e
        if [[ "$rc" -ne 0 ]]; then
          [[ "$rc" -eq 130 ]] && exit 130
          [[ "$rc" -eq "$BACK_EXIT" ]] && {
            step="target"
            [[ "$scope" == "REMOTE" ]] && step="remote-target"
            continue
          }
          die "Disko wizard failed"
        fi
        step="profile"
        ;;

      profile)
        ui_main_screen "System Profile" "disk layout" "hostname"
        machine_type="$(ui_choose "machine type" "laptop" "server")"
        [[ "$machine_type" == "$BACK_TOKEN" ]] && {
          step="configure"
          continue
        }
        [[ -n "$machine_type" ]] || die "machine type is required"
        step="hostname"
        ;;

      hostname)
        ui_main_screen "Hostname" "system profile" "user"
        install_hostname="$(ui_input "hostname:" "nixos" "${install_hostname:-}")"
        [[ "$install_hostname" == "$BACK_TOKEN" ]] && {
          step="profile"
          continue
        }
        [[ -n "$install_hostname" ]] || die "hostname is required"
        write_generated_host_config "$machine_type" "$install_hostname"
        step="user"
        ;;

      user)
        ui_main_screen "User" "hostname" "bin"
        install_user="$(ui_input "username:" "bresilla" "${install_user:-bresilla}")"
        [[ "$install_user" == "$BACK_TOKEN" ]] && {
          step="hostname"
          continue
        }
        [[ -n "$install_user" ]] || die "username is required"
        [[ "$install_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid username: $install_user"

        set_password="$(ui_confirm "Set initial password for $install_user?")" || set_password="no"
        if [[ "$set_password" != "no" ]]; then
          password_hash="$(hash_password_prompt "$install_user")"
          [[ "$password_hash" == "$BACK_TOKEN" ]] && {
            step="user"
            continue
          }
          INSTALL_PASSWORD_HASH_FILE="$password_hash"
        else
          INSTALL_PASSWORD_HASH_FILE=""
          ui_warn "No password will be set for $install_user. Password login and sudo password prompts will not work until you set one later."
        fi
        write_generated_user_config "$install_user" "$INSTALL_PASSWORD_HASH_FILE"
        step="bin"
        ;;

      bin)
        ui_main_screen "Bin" "user" "dotfiles"
        enable_bin="$(ui_choose "install default bin-managed CLI tools?" "yes" "no")"
        [[ "$enable_bin" == "$BACK_TOKEN" ]] && {
          step="user"
          continue
        }
        case "$enable_bin" in
          yes) write_generated_bin_config true ;;
          no) write_generated_bin_config false ;;
          *) die "bin selection is required" ;;
        esac
        step="dotfiles"
        ;;

      dotfiles)
        ui_main_screen "Dotfiles" "bin" "preflight"
        ui_note "Enter a Git repo to clone into /home/$install_user/.dot. Press Enter for the default, or type skip to skip dotfiles."
        dotfiles_repo="$(ui_input "dotfiles git repo:" "$DEFAULT_DOTFILES_REPO" "${dotfiles_repo:-$DEFAULT_DOTFILES_REPO}")"
        [[ "$dotfiles_repo" == "$BACK_TOKEN" ]] && {
          step="bin"
          continue
        }
        case "$dotfiles_repo" in
          "" | none | None | no | No | skip | Skip) dotfiles_repo="" ;;
        esac

        if [[ "$scope" == "REMOTE" ]]; then
          ui_main_screen "Preflight" "dotfiles" "review"
          preflight_generated_install "$machine_type" "$install_hostname" "$target"
          ui_main_screen "Install" "dotfiles" "run install"
          show_install_summary "Final review" "install-${machine_type}-generated" "$install_hostname" "$machine_type" "$target"
          ui_confirm "Start remote install to $target as $install_hostname ($machine_type)?" || {
            step="dotfiles"
            continue
          }
          INSTALL_USER="$install_user"
          DOTFILES_REPO="$dotfiles_repo"
          export INSTALL_USER DOTFILES_REPO
          remote_generated_install "$machine_type" "$install_hostname" "$target"
          return 0
        fi
        step="generated-mountpoint"
        ;;

      generated-mountpoint)
        ui_main_screen "Mountpoint" "dotfiles" "preflight"
        mountpoint="$(ui_input "mountpoint:" "" "${mountpoint:-/mnt}")"
        [[ "$mountpoint" == "$BACK_TOKEN" ]] && {
          step="dotfiles"
          continue
        }
        [[ -n "$mountpoint" ]] || die "mountpoint is required"
        ui_main_screen "Preflight" "mountpoint" "review"
        preflight_generated_install "$machine_type" "$install_hostname"
        ui_main_screen "Secrets" "mountpoint" "drop secrets"
        show_install_summary "Final review" "install-${machine_type}-generated" "$install_hostname" "$machine_type" "$mountpoint"
        ui_confirm "Drop local install secrets into $mountpoint for $install_hostname ($machine_type)?" || {
          step="dotfiles"
          continue
        }
        host="$install_hostname"
        INSTALL_USER="$install_user"
        DOTFILES_REPO="$dotfiles_repo"
        export INSTALL_PASSWORD_HASH_FILE INSTALL_USER DOTFILES_REPO
        exec "$repo_dir/install.sh" local "$install_hostname" "$mountpoint"
        ;;
    esac
  done
}

if [[ -z "$mode" ]]; then
  mode="interactive"
fi

case "$mode" in
  interactive)
    interactive_main
    ;;

  check)
    require_host
    load_host_key_context
    echo "repo: $repo_dir"
    echo "host: $host"
    echo "encrypted shared system key: $encrypted_key"
    echo "expected recipient: $expected_recipient"
    ;;

  key-check)
    require_host
    actual_recipient="$(check_host_key)"

    echo "repo: $repo_dir"
    echo "host: $host"
    echo "recipient: $actual_recipient"
    echo "key-check: ok"
    ;;

  preflight)
    role="${2:-}"
    host="${3:-}"
    target="${4:-}"
    [[ "$role" == "laptop" || "$role" == "server" ]] || die "preflight role must be laptop or server"
    require_host
    preflight_generated_install "$role" "$host" "$target"
    ;;

  remote)
    role="${2:-}"
    host="${3:-}"
    target="${4:-}"
    [[ "$role" == "laptop" || "$role" == "server" ]] || die "remote role must be laptop or server"
    require_host
    [[ -n "$target" ]] || {
      usage
      exit 2
    }
    shift 4
    remote_generated_install "$role" "$host" "$target" "$@"
    ;;

  local)
    require_host
    mountpoint="${3:-}"
    [[ -n "$mountpoint" ]] || {
      usage
      exit 2
    }

    command -v sops >/dev/null || die "sops is not in PATH"
    command -v age-plugin-yubikey >/dev/null || die "age-plugin-yubikey is not in PATH"
    [[ -d "$mountpoint" ]] || die "mountpoint does not exist: $mountpoint"

    install -d -m 0755 "$mountpoint/var/lib/sops-nix"
    decrypt_host_key > "$mountpoint/var/lib/sops-nix/key.txt"
    chmod 0600 "$mountpoint/var/lib/sops-nix/key.txt"
    if [[ -n "$INSTALL_PASSWORD_HASH_FILE" ]]; then
      install -d -m 0755 "$mountpoint/var/lib/nixos-install"
      install -m 0600 "$INSTALL_PASSWORD_HASH_FILE" "$mountpoint$INSTALL_PASSWORD_HASH_TARGET"
    fi
    if [[ -n "${DOTFILES_REPO:-}" ]]; then
      local_run_dotfiles "$mountpoint" "${INSTALL_USER:-bresilla}" "$DOTFILES_REPO"
    fi
    ;;

  *)
    usage
    exit 2
    ;;
esac
