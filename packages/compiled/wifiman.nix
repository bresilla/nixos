{ writeShellApplication, coreutils, curl, jq, socat, util-linux, xdg-utils }:

# Teleport from the terminal, through the WiFiman daemon's local API.
writeShellApplication {
  name = "wifiman";
  runtimeInputs = [ coreutils curl jq socat util-linux xdg-utils ];
  text = ''
    socket=/var/run/wifiman-desktop.sock
    api=http://127.0.0.1:63150

    # The daemon hands its API token to the logged-in desktop user over the socket.
    token() { socat -u "UNIX-CONNECT:$socket" -; }

    call() {
      local method=$1 path=$2; shift 2
      curl -fsS --max-time "''${WIFIMAN_TIMEOUT:-45}" -X "$method" \
        -H "Authorization: Bearer $TOKEN" \
        -H "X-WiFiman-Client: cli" \
        -H "Content-Type: application/json" \
        "$@" "$api$path"
    }

    cache=''${XDG_CACHE_HOME:-$HOME/.cache}/wifiman/consoles.json

    # The daemon fetches the list from Ubiquiti's cloud; each answer is kept for when it is slow.
    consoles() {
      local list
      if list=$(call POST /teleport/connections -d '{}') && [ "$(jq length <<<"$list")" -gt 0 ]; then
        mkdir -p "''${cache%/*}"
        (umask 077; printf '%s' "$list" >"$cache")
        printf '%s' "$list"
      elif [ -f "$cache" ]; then
        echo "wifiman: the daemon did not answer; using the saved console list" >&2
        cat "$cache"
      else
        echo "wifiman: the daemon did not list any consoles" >&2
        exit 1
      fi
    }

    # A console's invitation secret identifies it in every Teleport request.
    secret_of() {
      local secret
      secret=$(consoles | jq -r --arg n "$1" '.[] | select(.name == $n) | .invitationSecret' | head -1)
      [ -n "$secret" ] || { echo "wifiman: no console named '$1'; see wifiman list" >&2; exit 1; }
      printf '%s' "$secret"
    }

    with_secret() { jq -n --arg s "$1" '{invitationSecret: $s}'; }

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
      blob=''${link#wifiman-desktop-dl://sso.ui.link/}
      blob=$(printf '%b' "''${blob//%/\\x}")
      # Decrypted, the blob is "accessToken<TAB>refreshToken<TAB>expiresIn".
      tokens=$(call POST /crypto/decrypt -d "$(jq -n --arg p "$private" --arg t "$blob" '{privKey: $p, tokens: $t}')" | jq -r .)
      IFS=$'\t' read -r access refresh expires <<<"$tokens"
      call POST /sso/auth -d "$(jq -n --arg a "$access" --arg r "$refresh" --arg e "$expires" \
        '{accessToken: $a, refreshToken: $r, expiresIn: ($e | tonumber)}')" | jq '{username, email}'
    }

    list() {
      consoles | jq -r '.[] | [.name, .model, (.state | sub("console.state."; "")),
        (.source | sub("console.source."; "")), .location.text] | @tsv' |
        column -t -s $'\t' -N NAME,MODEL,STATE,SOURCE,LOCATION
    }

    status() {
      call POST /teleport/connection/status |
        jq '{state: (.state | sub("connection.state."; "")), rx: .statistics.rx, tx: .statistics.tx,
          since: (if .stateChangedAt > 0 then (.stateChangedAt / 1000 | todate) else null end)}'
    }

    on() { WIFIMAN_TIMEOUT=90 call POST /teleport/on -d "$(with_secret "$(secret_of "$1")")" >/dev/null && status; }

    # Without a name, the connection that is up now goes down.
    off() {
      local secret
      if [ $# -ge 1 ]; then secret=$(secret_of "$1"); else secret=$(call POST /teleport/connection/status | jq -r .invitationSecret); fi
      call POST /teleport/off -d "$(with_secret "$secret")" >/dev/null && status
    }

    # An invite link or its bare secret, the part after the last "/" or "#".
    add() {
      local secret=''${1##*[/#]}
      call POST /teleport/consoles/add -d "$(with_secret "$secret")" | jq .
    }

    remove() { call POST /teleport/consoles/remove -d "$(with_secret "$(secret_of "$1")")" | jq .; }

    usage() {
      cat >&2 <<EOF
    usage: wifiman <command>
      login              log in with your UI account in the browser
      user               show the logged-in account
      list               consoles you can reach
      on <console>       connect to a console over Teleport
      off [console]      disconnect (the current connection by default)
      status             connection state and traffic
      add <invite>       add a console from a Teleport invite link
      remove <console>   forget an invited console
    EOF
      exit 2
    }

    [ $# -ge 1 ] || usage
    TOKEN=$(token)
    command=$1; shift
    case $command in
      login) login ;;
      user) call GET /sso/user | jq '{username, email, first_name, last_name}' ;;
      list) list ;;
      status) status ;;
      on) [ $# -eq 1 ] || usage; on "$1" ;;
      off) off "$@" ;;
      add) [ $# -eq 1 ] || usage; add "$1" ;;
      remove) [ $# -eq 1 ] || usage; remove "$1" ;;
      *) usage ;;
    esac
  '';
}
