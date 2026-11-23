#!/usr/bin/env bash
# Signs a new intermediate for cert.bresilla.com with the root key from gopass, limited
# to bresilla.com names, so the CA cannot vouch for any other site even if hive is taken.
# Run with a YubiKey for gopass at hand; then rebuild hive and restart container@ca.
set -euo pipefail

repo=$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
pki=$repo/shared/system/pki
hive=${HIVE:-hive.netbird}
secrets=/var/lib/nixos-containers/ca/var/lib/step-ca-secrets
PATH="$(nix build --no-link --print-out-paths nixpkgs#step-cli)/bin:$PATH"
[ -d "${PASSWORD_STORE_DIR:-}" ] || unset PASSWORD_STORE_DIR

work=$(mktemp -d -p /dev/shm)
trap 'find "$work" -type f -exec shred -u {} + ; rm -rf "$work"' EXIT
cd "$work"

cat > intermediate.tpl <<'EOF'
{
  "subject": {{ toJson .Subject }},
  "keyUsage": ["certSign", "crlSign"],
  "basicConstraints": {"isCA": true, "maxPathLen": 0},
  "nameConstraints": {"critical": true, "permittedDNSDomains": ["bresilla.com"]}
}
EOF

echo "gopass asks for a YubiKey touch for the root key:"
gopass show -n -f pki/bresilla/root-key > root.key
grep -q "BEGIN .*PRIVATE KEY" root.key || { echo "pki/bresilla/root-key did not come out as a PEM key" >&2; exit 1; }
head -c 32 /dev/urandom | base64 | tr -d '\n=/+' > password
step certificate create "bresilla Intermediate CA" intermediate.crt intermediate.key \
  --template intermediate.tpl --ca "$pki/bresilla-root.crt" --ca-key root.key \
  --kty EC --curve P-256 --not-after 43800h --password-file password
step certificate inspect intermediate.crt --short

echo "gopass asks for a YubiKey touch for each of two entries:"
gopass insert -f -m pki/bresilla/intermediate-key < intermediate.key
gopass insert -f -m pki/bresilla/intermediate-password < password
install -m 0644 intermediate.crt "$pki/bresilla-intermediate.crt"

tmp=$(ssh "$hive" 'mktemp -d')
scp -q intermediate.key password "$hive:$tmp/"
echo "hive's sudo asks for your password on hive:"
ssh -t "$hive" "sudo install -m 0600 $tmp/intermediate.key $secrets/intermediate_key \
  && sudo install -m 0600 $tmp/password $secrets/password; shred -u $tmp/*; rm -rf $tmp"
echo "Done: commit $pki/bresilla-intermediate.crt, update hive, then restart container@ca."
