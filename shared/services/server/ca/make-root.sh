#!/usr/bin/env bash
# Creates bresilla's root CA once, with both YubiKeys at hand. The root key is made
# in memory, put on each YubiKey (PIV slot 9c, PIN and touch to use) and into
# gopass, and used once to sign the intermediate that cert.bresilla.com runs on.
# The certificates go into the repo; the intermediate's key and password go to hive.
set -euo pipefail

repo=$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
pki=$repo/shared/system/pki
hive=${HIVE:-hive.netbird}
slot=9c
secrets=/var/lib/nixos-containers/ca/var/lib/step-ca-secrets

[ -e "$pki/bresilla-root.crt" ] && { echo "A root already exists: $pki/bresilla-root.crt" >&2; exit 1; }
for p in step-cli yubikey-manager; do
  PATH="$(nix build --no-link --print-out-paths "nixpkgs#$p")/bin:$PATH"
done

# Only memory, never disk; whatever is left is shredded on the way out.
work=$(mktemp -d -p /dev/shm)
trap 'find "$work" -type f -exec shred -u {} + ; rm -rf "$work"' EXIT
cd "$work"

step certificate create "bresilla Root CA" root.crt root.key \
  --profile root-ca --kty EC --curve P-256 --not-after 87600h --no-password --insecure
head -c 32 /dev/urandom | base64 | tr -d '\n=/+' > password
step certificate create "bresilla Intermediate CA" intermediate.crt intermediate.key \
  --profile intermediate-ca --ca root.crt --ca-key root.key \
  --kty EC --curve P-256 --not-after 43800h --password-file password

# The root on each YubiKey: slot 9c must be free, the age keys sit in 82 and up.
for n in 1 2; do
  read -rp "Insert YubiKey $n of 2 (only that one) and press Enter: "
  if ykman piv info | grep -qi "slot $slot"; then
    echo "Slot $slot on this YubiKey is in use; nothing was written to it." >&2
    exit 1
  fi
  echo "ykman asks for this YubiKey's PIV PIN (the one gopass uses):"
  ykman piv keys import --pin-policy always --touch-policy always "$slot" root.key
  ykman piv certificates import "$slot" root.crt
done

# A copy only your YubiKeys can open, for a third key or a lost one.
echo "gopass asks for a YubiKey touch to store the root key and the password:"
gopass insert -m pki/bresilla/root-key < root.key
gopass insert -m pki/bresilla/intermediate-password < password

install -D -m 0644 root.crt "$pki/bresilla-root.crt"
install -D -m 0644 intermediate.crt "$pki/bresilla-intermediate.crt"

# The intermediate's key and password to hive, where only the CA container reads them.
tmp=$(ssh "$hive" 'mktemp -d')
scp -q intermediate.key password "$hive:$tmp/"
echo "hive's sudo asks for your password on hive:"
ssh -t "$hive" "sudo install -d -m 0700 $secrets \
  && sudo install -m 0600 $tmp/intermediate.key $secrets/intermediate_key \
  && sudo install -m 0600 $tmp/password $secrets/password; shred -u $tmp/*; rm -rf $tmp"

echo
echo "Done. Root fingerprint:"
step certificate fingerprint root.crt
echo "Commit shared/system/pki/ and update hive; cert.bresilla.com then starts."
