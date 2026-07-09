#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

remote="${1:-nixos@192.168.1.75}"
host="${2:-novo}"
flake_ref="${3:-/tmp/nx-source#install-laptop-generated}"
key_file="${NIXOS_INSTALL_DECRYPTED_KEY_FILE:-/dev/shm/nixos-install-system-key.finish}"
role="${ROLE:-laptop}"
install_user="${INSTALL_USER:-bresilla}"
dotfiles_repo="${DOTFILES_REPO:-https://github.com/bresilla/dot.git}"

run_nixos_install="${RUN_NIXOS_INSTALL:-1}"
run_config_copy="${RUN_CONFIG_COPY:-1}"
run_bin="${RUN_BIN:-1}"
run_dotfiles="${RUN_DOTFILES:-0}"
run_reboot="${REBOOT:-0}"

github_token_file=""
dotfiles_tmp=""

ssh() {
  command ssh \
    -F "${NIXOS_INSTALL_SSH_CONFIG:-/dev/null}" \
    -o "UserKnownHostsFile=${NIXOS_INSTALL_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}" \
    -o "StrictHostKeyChecking=${NIXOS_INSTALL_SSH_HOST_KEY_POLICY:-accept-new}" \
    "$@"
}

usage() {
  cat >&2 <<EOF
Usage:
  scripts/finish-remote-install.sh [remote] [host] [flake-ref]

Defaults:
  remote:    nixos@192.168.1.75
  host:      novo
  flake-ref: /tmp/nx-source#install-laptop-generated

Environment:
  ROLE=laptop|server          target system role, default: laptop
  INSTALL_USER=name           user for optional dotfiles, default: bresilla
  RUN_NIXOS_INSTALL=0|1       rerun nixos-install, default: 1
  RUN_CONFIG_COPY=0|1         copy repo to /mnt/etc/nixos, default: 1
  RUN_BIN=0|1                 run system bin ensure in chroot, default: 1
  RUN_DOTFILES=0|1            clone and run dotfiles in chroot, default: 0
  DOTFILES_REPO=url           dotfiles repo for RUN_DOTFILES=1
  REBOOT=0|1                  reboot remote target at end, default: 0

This script:
  1. decrypts the shared system age identity through ./install.sh key-check
  2. extracts the GitHub token once with that identity
  3. copies the decrypted identity into /mnt/var/lib/sops-nix/key.txt
  4. optionally reruns nixos-install against the mounted target
  5. copies this repo into /mnt/etc/nixos with group corner ownership
  6. optionally runs system bin ensure in the installed-system chroot
  7. optionally runs dotfiles and reboots
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

quote() {
  printf '%q' "$1"
}

is_enabled() {
  case "$1" in
    1 | yes | true | on) return 0 ;;
    0 | no | false | off) return 1 ;;
    *) echo "error: expected boolean 0/1, yes/no, true/false, or on/off: $1" >&2; exit 1 ;;
  esac
}

cleanup() {
  [[ -n "$github_token_file" ]] && rm -f -- "$github_token_file"
  [[ -n "$dotfiles_tmp" ]] && rm -rf -- "$dotfiles_tmp"
}
trap cleanup EXIT

require_tool() {
  command -v "$1" >/dev/null || {
    echo "error: $1 is not in PATH" >&2
    exit 1
  }
}

extract_github_token() {
  require_tool sops
  github_token_file="$(mktemp "${TMPDIR:-/tmp}/nixos-install-github-token.XXXXXX")"
  chmod 0600 "$github_token_file"

  SOPS_AGE_KEY_FILE="$key_file" sops --decrypt "$repo_dir/secrets/common/github.yaml" |
    awk '
      /^[[:space:]]*github:[[:space:]]*$/ { in_github = 1; next }
      in_github && /^[^[:space:]]/ { in_github = 0 }
      in_github && /^[[:space:]]*token:[[:space:]]*/ {
        sub(/^[[:space:]]*token:[[:space:]]*/, "")
        gsub(/^"|"$/, "")
        gsub(/^'\''|'\''$/, "")
        print
        found = 1
        exit
      }
      END { exit found ? 0 : 1 }
    ' > "$github_token_file"

  [[ -s "$github_token_file" ]] || {
    echo "error: could not extract github.token from secrets/common/github.yaml" >&2
    exit 1
  }
}

tar_nix_config_repo() {
  (
    cd "$repo_dir"
    tar \
      --exclude='./.agents' \
      --exclude='./.codex' \
      --exclude='./.cloudflare' \
      --exclude='./.direnv' \
      --exclude='./specific' \
      --exclude='./rewrite/target' \
      --exclude='./target' \
      --exclude='./result' \
      --exclude='./result-bin' \
      --exclude='./secrets/key.txt' \
      -cf - .
  )
}

install_remote_config_copy_script() {
  ssh "$remote" 'cat > /tmp/nixos-config-copy.sh && chmod 0700 /tmp/nixos-config-copy.sh' <<'REMOTE_CONFIG_COPY'
#!/usr/bin/env bash
set -euo pipefail

role="$1"
install_user="$2"
dest="/mnt/etc/nixos"

case "$role" in
  laptop | server) ;;
  *) echo "role must be laptop or server" >&2; exit 1 ;;
esac

[[ -d /mnt/etc ]] || {
  echo "installed system is not mounted at /mnt" >&2
  exit 1
}

rm -rf "$dest"
install -d -m 2775 "$dest"
tar -xf - -C "$dest"
printf '%s\n' "$role" > "$dest/.nixos-role"

if [[ -f "$dest/.git/config" ]]; then
  sed -i 's#git@github.com:bresilla/nixos.git#https://github.com/bresilla/nixos.git#g' "$dest/.git/config" || true
fi

install -d -m 2775 "$dest/specific"
if [[ ! -f "$dest/specific/configuration.nix" ]]; then
  cat > "$dest/specific/configuration.nix" <<'SPECIFIC_CONFIG'
{ ... }:

{
  # Host-specific local overrides go here.
}
SPECIFIC_CONFIG
fi

corner_gid="$(awk -F: '$1 == "corner" { print $3 }' /mnt/etc/group)"
[[ -n "$corner_gid" ]] || {
  echo "could not find target group in /mnt/etc/group: corner" >&2
  exit 1
}

chown -R "0:$corner_gid" "$dest"
chmod -R g+rwX "$dest"
find "$dest" -type d -exec chmod g+s {} +
chmod 2775 "$dest"

user_home="/mnt/home/$install_user"
if [[ -d "$user_home" ]]; then
  user_uid="$(awk -F: -v user="$install_user" '$1 == user { print $3 }' /mnt/etc/passwd)"
  user_gid="$(awk -F: -v user="$install_user" '$1 == user { print $4 }' /mnt/etc/passwd)"
  user_gitconfig="$user_home/.gitconfig"
  if ! grep -qs '^[[:space:]]*directory = /etc/nixos$' "$user_gitconfig" 2>/dev/null; then
    cat >> "$user_gitconfig" <<'GITCONFIG'
[safe]
	directory = /etc/nixos
GITCONFIG
  fi
  if [[ -n "$user_uid" && -n "$user_gid" ]]; then
    chown "$user_uid:$user_gid" "$user_gitconfig" || true
  fi
fi
REMOTE_CONFIG_COPY
}

copy_config_repo() {
  echo "==> Copying NixOS config repo into /mnt/etc/nixos"
  install_remote_config_copy_script
  tar_nix_config_repo |
    ssh "$remote" "if command -v sudo >/dev/null 2>&1; then sudo --non-interactive bash /tmp/nixos-config-copy.sh $(quote "$role") $(quote "$install_user"); else bash /tmp/nixos-config-copy.sh $(quote "$role") $(quote "$install_user"); fi"
}

copy_shared_key() {
  echo "==> Copying decrypted key into mounted target"
  ssh "$remote" \
    'sudo install -d -m 0755 /mnt/var/lib/sops-nix; sudo sh -c "umask 077; cat > /mnt/var/lib/sops-nix/key.txt"; sudo chmod 0600 /mnt/var/lib/sops-nix/key.txt' \
    < "$key_file"
}

copy_github_token_to_target() {
  ssh "$remote" \
    "if command -v sudo >/dev/null 2>&1; then sudo --non-interactive sh -c 'install -d -m 1777 /mnt/tmp; umask 077; cat > /mnt/tmp/nixos-install-github-token'; else sh -c 'install -d -m 1777 /mnt/tmp; umask 077; cat > /mnt/tmp/nixos-install-github-token'; fi" \
    < "$github_token_file"
}

run_system_bin_ensure() {
  echo "==> Running system bin ensure inside installed system chroot"
  copy_github_token_to_target
  ssh "$remote" 'cat > /tmp/nixos-bin-ensure-run.sh && chmod 0700 /tmp/nixos-bin-ensure-run.sh' <<'REMOTE_BIN_ENSURE_RUN'
#!/usr/bin/env bash
set -euo pipefail

[[ -d /mnt/nix/var/nix/profiles ]] || {
  echo "installed system is not mounted at /mnt" >&2
  exit 1
}

cat > /mnt/tmp/nixos-bin-ensure-chroot.sh <<'CHROOT_BIN_ENSURE'
#!/usr/bin/env bash
set -euo pipefail

github_token_file="/tmp/nixos-install-github-token"
trap 'rm -f "$github_token_file"' EXIT

if [[ -r "$github_token_file" ]]; then
  github_token="$(<"$github_token_file")"
  export GITHUB_TOKEN="$github_token"
  export GITHUB_AUTH_TOKEN="$github_token"
fi

bin ensure
if [[ -d /usr/local/bin ]]; then
  find /usr/local/bin -maxdepth 1 -type f -exec chmod 0755 {} +
fi
CHROOT_BIN_ENSURE

chmod 0700 /mnt/tmp/nixos-bin-ensure-chroot.sh
nixos-enter --root /mnt --command "/nix/var/nix/profiles/system/sw/bin/bash /tmp/nixos-bin-ensure-chroot.sh"
REMOTE_BIN_ENSURE_RUN

  ssh -tt "$remote" \
    'if command -v sudo >/dev/null 2>&1; then sudo --non-interactive bash /tmp/nixos-bin-ensure-run.sh; else bash /tmp/nixos-bin-ensure-run.sh; fi' < /dev/tty
}

prepare_dotfiles_checkout() {
  require_tool git
  dotfiles_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nixos-install-dotfiles.XXXXXX")"
  echo "==> Cloning dotfiles repo: $dotfiles_repo"
  git clone --recursive "$dotfiles_repo" "$dotfiles_tmp/dotfiles"
  [[ -f "$dotfiles_tmp/dotfiles/run_me.sh" ]] || {
    echo "error: dotfiles checkout missing run_me.sh" >&2
    exit 1
  }
  chmod +x "$dotfiles_tmp/dotfiles/run_me.sh"
}

copy_and_run_dotfiles() {
  [[ "$install_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
    echo "error: invalid install user: $install_user" >&2
    exit 1
  }

  prepare_dotfiles_checkout
  copy_github_token_to_target

  echo "==> Copying dotfiles into /mnt/home/$install_user/.dot"
  (
    cd "$dotfiles_tmp/dotfiles"
    tar -cf - .
  ) | ssh "$remote" \
    "if command -v sudo >/dev/null 2>&1; then sudo --non-interactive sh -c 'rm -rf /mnt/home/$(quote "$install_user")/.dot && mkdir -p /mnt/home/$(quote "$install_user")/.dot && tar -xf - -C /mnt/home/$(quote "$install_user")/.dot'; else sh -c 'rm -rf /mnt/home/$(quote "$install_user")/.dot && mkdir -p /mnt/home/$(quote "$install_user")/.dot && tar -xf - -C /mnt/home/$(quote "$install_user")/.dot'; fi"

  echo "==> Running dotfiles ./run_me.sh inside installed system chroot"
  ssh "$remote" 'cat > /tmp/nixos-dotfiles-run.sh && chmod 0700 /tmp/nixos-dotfiles-run.sh' <<'REMOTE_DOTFILES_RUN'
#!/usr/bin/env bash
set -euo pipefail

install_user="$1"
cat > /mnt/tmp/nixos-dotfiles-run-chroot.sh <<'CHROOT_DOTFILES_RUN'
#!/usr/bin/env bash
set -euo pipefail

install_user="$1"
home_dir="/home/$install_user"
dot_dir="$home_dir/.dot"
github_token_file="/tmp/nixos-install-github-token"
trap 'rm -f "$github_token_file"' EXIT

if [[ -r "$github_token_file" ]]; then
  github_token="$(<"$github_token_file")"
  export GITHUB_TOKEN="$github_token"
  export GITHUB_AUTH_TOKEN="$github_token"
fi

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
env PATH="$sudo_shim_dir:$PATH" HOME="$home_dir" USER="$install_user" LOGNAME="$install_user" bash ./run_me.sh
run_me_status=$?
unset GITHUB_TOKEN GITHUB_AUTH_TOKEN
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

  ssh -tt "$remote" \
    "if command -v sudo >/dev/null 2>&1; then sudo --non-interactive bash /tmp/nixos-dotfiles-run.sh $(quote "$install_user"); else bash /tmp/nixos-dotfiles-run.sh $(quote "$install_user"); fi" < /dev/tty
}

reboot_target() {
  echo "==> Rebooting target"
  ssh "$remote" \
    'if command -v sudo >/dev/null 2>&1; then sudo --non-interactive sh -c "sync; nohup sh -c '\''sleep 3; if command -v systemctl >/dev/null 2>&1; then systemctl reboot --force; else reboot -f; fi'\'' >/dev/null 2>&1 &"; else sh -c "sync; nohup sh -c '\''sleep 3; if command -v systemctl >/dev/null 2>&1; then systemctl reboot --force; else reboot -f; fi'\'' >/dev/null 2>&1 &"; fi'
}

case "$role" in
  laptop | server) ;;
  *) echo "error: ROLE must be laptop or server: $role" >&2; exit 1 ;;
esac

echo "remote: $remote"
echo "host: $host"
echo "flake: $flake_ref"
echo "role: $role"
echo "install user: $install_user"
echo "decrypted key cache: $key_file"
echo

require_tool ssh
require_tool tar

cd "$repo_dir"

echo "==> Decrypting shared system key"
NIXOS_INSTALL_DECRYPTED_KEY_FILE="$key_file" \
NIXOS_INSTALL_DECRYPTED_KEY_FILE_OWNED=0 \
  ./install.sh key-check "$host"

[[ -s "$key_file" ]] || {
  echo "error: decrypted key was not written: $key_file" >&2
  exit 1
}

echo "==> Extracting GitHub token once"
extract_github_token

echo "==> Checking remote /mnt"
ssh "$remote" 'findmnt /mnt >/dev/null'

copy_shared_key

if is_enabled "$run_nixos_install"; then
  echo "==> Rerunning nixos-install"
  ssh "$remote" "sudo nixos-install --flake $(quote "$flake_ref") --no-root-passwd"
else
  echo "==> Skipping nixos-install"
fi

if is_enabled "$run_config_copy"; then
  copy_config_repo
else
  echo "==> Skipping /mnt/etc/nixos copy"
fi

if is_enabled "$run_bin"; then
  run_system_bin_ensure
else
  echo "==> Skipping system bin ensure"
fi

if is_enabled "$run_dotfiles"; then
  copy_and_run_dotfiles
else
  echo "==> Skipping dotfiles"
fi

if is_enabled "$run_reboot"; then
  reboot_target
else
  echo "==> Not rebooting; set REBOOT=1 to reboot target"
fi

echo "finish-remote-install: ok"
