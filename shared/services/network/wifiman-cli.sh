#!/usr/bin/env bash
# WiFiman Teleport without the GUI: talks to wifiman-desktopd's local API.
set -euo pipefail

socket=/var/run/wifiman-desktop.sock
api=http://127.0.0.1:63150

# The daemon hands its API token to the logged-in desktop user over the socket.
token() { socat -u "UNIX-CONNECT:$socket" -; }

call() {
  local method=$1 path=$2; shift 2
  curl -fsS -X "$method" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-WiFiman-Client: cli" \
    -H "Content-Type: application/json" \
    "$@" "$api$path"
}

# SSO: the browser returns the login tokens encrypted to a key pair the daemon made.
login() {
  local keys public private url link blob tokens access refresh expires
  keys=$(call GET /crypto/genRSA/1024)
  public=$(jq -r .Public <<<"$keys")
  private=$(jq -r .Private <<<"$keys")
  url="https://sp-dir.uwn.com/auth/sso/desktop?key=$(jq -rn --arg k "$public" '$k|@uri')"
  echo "Log in at: $url"
  xdg-open "$url" >/dev/null 2>&1 || true
  read -rp "Paste the wifiman-desktop-dl:// link the browser offers: " link
  blob=${link#wifiman-desktop-dl://sso.ui.link/}
  blob=$(printf '%b' "${blob//%/\\x}")
  # Decrypted, the blob is "accessToken<TAB>refreshToken<TAB>expiresIn".
  tokens=$(call POST /crypto/decrypt -d "$(jq -n --arg p "$private" --arg t "$blob" '{privKey: $p, tokens: $t}')" | jq -r .)
  IFS=$'\t' read -r access refresh expires <<<"$tokens"
  call POST /sso/auth -d "$(jq -n --arg a "$access" --arg r "$refresh" --arg e "$expires" \
    '{accessToken: $a, refreshToken: $r, expiresIn: ($e | tonumber)}')" | jq '{username, email}'
}

usage() {
  echo "usage: wifiman login|user|status|raw <METHOD> <path> [json]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
TOKEN=$(token)
case $1 in
  login) login ;;
  user) call GET /sso/user | jq . ;;
  status) call POST /teleport/connection/status | jq . ;;
  raw) [ $# -ge 3 ] || usage; call "$2" "$3" ${4:+-d "$4"} | jq . ;;
  *) usage ;;
esac
