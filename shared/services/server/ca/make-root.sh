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
# A session can carry a stale PASSWORD_STORE_DIR (/pass); gopass's own config
# knows the store, so a path that isn't there is dropped. Checked before anything.
[ -d "${PASSWORD_STORE_DIR:-}" ] || unset PASSWORD_STORE_DIR
gopass ls --flat >/dev/null || { echo "gopass does not open its store; nothing was created." >&2; exit 1; }

# Both YubiKeys first, before anything exists: two different keys, slot 9c free
# on each. The age keys sit in the retired slots, 82 and up.
serials=()
for n in 1 2; do
  read -rp "Insert YubiKey $n of 2, and only that one, then press Enter: "
  mapfile -t found < <(ykman list --serials)
  [ "${#found[@]}" -eq 1 ] || { echo "Expected exactly one YubiKey, found ${#found[@]}." >&2; exit 1; }
  s=${found[0]}
  [ "$n" -eq 2 ] && [ "$s" = "${serials[0]}" ] && { echo "That is YubiKey 1 again (serial $s); swap it for the other one." >&2; exit 1; }
  if ykman --device "$s" piv info | grep -qi "slot $slot"; then
    echo "Slot $slot on YubiKey $s is in use; nothing was created." >&2
    exit 1
  fi
  echo "YubiKey $n: serial $s, slot $slot free."
  serials+=("$s")
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

# Saved first, so nothing after this can lose them: the keys and password in
# gopass, which only your YubiKeys open, and the two certificates in the repo.
read -rp "Insert a YubiKey for gopass, then press Enter: "
echo "gopass asks for a YubiKey touch for each of three entries:"
gopass insert -m pki/bresilla/root-key < root.key
gopass insert -m pki/bresilla/intermediate-key < intermediate.key
gopass insert -m pki/bresilla/intermediate-password < password
install -D -m 0644 root.crt "$pki/bresilla-root.crt"
install -D -m 0644 intermediate.crt "$pki/bresilla-intermediate.crt"

# The root onto each of those two YubiKeys, by serial.
for s in "${serials[@]}"; do
  until [ "$(ykman list --serials)" = "$s" ]; do
    read -rp "Insert only YubiKey $s, then press Enter: "
  done
  echo "ykman asks for YubiKey $s's PIV PIN (the one gopass uses):"
  ykman --device "$s" piv keys import --pin-policy always --touch-policy always "$slot" root.key
  ykman --device "$s" piv certificates import "$slot" root.crt
done

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
