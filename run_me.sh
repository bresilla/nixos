#!/usr/bin/env bash
set -euo pipefail

remote="${REMOTE:-nixos@192.168.122.216}"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agent_binary="${AGENT_BINARY:-}"
# Decrypt install secrets with a local age key file instead of the YubiKey.
# Point NX_AGE_KEY_FILE at the plaintext system age key (the decrypted key.txt).
# When the self-contained secrets-test/ fixture exists, use its key by default
# (generate it with: nix-shell -p age sops --run scripts/setup-test-secrets.sh).
age_key_file="${NX_AGE_KEY_FILE:-}"
if [[ -z "$age_key_file" && -f "$repo_dir/secrets-test/key.txt" ]]; then
  age_key_file="$repo_dir/secrets-test/key.txt"
fi

if [[ -z "${NX_RUN_ME_INSIDE_SCRIPT:-}" && -t 1 ]] && command -v script >/dev/null 2>&1; then
  log_dir="${NX_RUN_LOG_DIR:-$repo_dir/.run-logs}"
  mkdir -p "$log_dir"
  log_file="$log_dir/run_me-$(date +%Y%m%d-%H%M%S).typescript"
  echo "Logging terminal transcript to $log_file"
  if script --help 2>&1 | grep -q -- '--return'; then
    exec script --quiet --flush --return --append "$log_file" -- \
      env NX_RUN_ME_INSIDE_SCRIPT=1 REMOTE="$remote" AGENT_BINARY="$agent_binary" \
      NX_AGENT_SOURCE="${NX_AGENT_SOURCE:-}" NX_AGE_KEY_FILE="$age_key_file" bash "$repo_dir/run_me.sh"
  fi
  exec script -q -f "$log_file" -- \
    env NX_RUN_ME_INSIDE_SCRIPT=1 REMOTE="$remote" AGENT_BINARY="$agent_binary" \
    NX_AGENT_SOURCE="${NX_AGENT_SOURCE:-}" NX_AGE_KEY_FILE="$age_key_file" bash "$repo_dir/run_me.sh"
fi

if [[ -z "$agent_binary" ]]; then
  remote_source="${NX_AGENT_SOURCE:-/tmp/nx-agent-source}"
  ssh_args=(-F /dev/null -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -o StrictHostKeyChecking=accept-new)

  echo "Copying current repo to $remote:$remote_source for agent build."
  ssh "${ssh_args[@]}" "$remote" "rm -rf '$remote_source' && mkdir -p '$remote_source'"
  tar \
    --exclude='./.git' \
    --exclude='./rewrite/target' \
    -C "$repo_dir" \
    -czf - . | ssh "${ssh_args[@]}" "$remote" "tar -xzf - -C '$remote_source'"

  echo "Building nx-rs agent on $remote."
  agent_store="$(
    ssh "${ssh_args[@]}" "$remote" \
      "nix --extra-experimental-features 'nix-command flakes' build --impure --no-link --print-out-paths --expr 'let flake = builtins.getFlake \"path:$remote_source\"; pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; }; in pkgs.callPackage $remote_source/rewrite/package.nix {}'"
  )"
  agent_binary="$agent_store/bin/nx-rs"
fi

exec_args=(
  remote-install-exec
  --remote "$remote"
  --agent-binary "$agent_binary"
  --transfer-source
  --allow-ssh
  --overwrite-existing-storage
  --allow-destructive
  --confirm-destructive-target "$remote"
  --max-destructive-steps 9
)
if [[ -n "$age_key_file" ]]; then
  echo "Using local age key file for secrets: $age_key_file"
  exec_args+=(--age-key-file "$age_key_file")
fi

cargo run --manifest-path rewrite/Cargo.toml -- "${exec_args[@]}"
