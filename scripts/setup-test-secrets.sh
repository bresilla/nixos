#!/usr/bin/env bash
# Generate a self-contained test secrets fixture: a fresh age key plus dummy
# secrets encrypted to it, matching every key modules/secrets.nix expects.
#
# The result lives in secrets-test/ (gitignored). When present, the installer and
# the transferred flake source use it in place of the real, YubiKey-locked
# secrets/, so the full install can be exercised on a disposable target without a
# YubiKey. Nothing here decrypts or touches the real secrets.
#
# Requires: age-keygen, sops (e.g. `nix-shell -p age sops --run scripts/setup-test-secrets.sh`).
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$repo/secrets-test"
key="$dir/key.txt"

for tool in age-keygen sops; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: $tool not found; run inside 'nix-shell -p age sops'" >&2
    exit 1
  }
done

mkdir -p "$dir/common"

if [[ -f "$key" ]]; then
  echo "reusing existing test age key: $key"
else
  age-keygen -o "$key" >/dev/null 2>&1
  chmod 0600 "$key"
  echo "generated test age key: $key"
fi
recipient="$(age-keygen -y "$key")"
echo "test recipient: $recipient"

# sops resolves .sops.yaml from the working directory upward, which would pick up
# the repo's real config. Run every encryption from an isolated temp workdir and
# drive recipients purely through SOPS_AGE_RECIPIENTS.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

encrypt_yaml() { # <plaintext-content> <output-file>
  local content="$1" out="$2" tmp
  tmp="$work/in.yaml"
  printf '%s' "$content" >"$tmp"
  ( cd "$work" && SOPS_AGE_RECIPIENTS="$recipient" sops --encrypt --input-type yaml --output-type yaml "$tmp" ) >"$out"
  echo "wrote $out"
}

encrypt_binary() { # <plaintext-content> <output-file>
  local content="$1" out="$2" tmp
  tmp="$work/in.bin"
  printf '%s' "$content" >"$tmp"
  ( cd "$work" && SOPS_AGE_RECIPIENTS="$recipient" sops --encrypt --input-type binary --output-type binary "$tmp" ) >"$out"
  echo "wrote $out"
}

encrypt_yaml 'netbird:
  setup_key: test-netbird-setup-key
wireguard:
  private_key: test-wireguard-private-key
wifi:
  home_psk: test-wifi-home-psk
wur:
  access_creds: test-wur-access-creds
  access_pem: test-wur-access-pem
  eduroam_8021x: test-wur-eduroam-8021x
' "$dir/system.yaml"

encrypt_yaml 'github:
  token: ghp_test_dummy_token
' "$dir/common/github.yaml"

encrypt_binary '# test hosts fixture
127.0.0.1 test.local
' "$dir/common/hosts"

echo
echo "test secrets ready under $dir"
echo "run the installer with these by exporting:"
echo "  export NX_AGE_KEY_FILE=$key"
