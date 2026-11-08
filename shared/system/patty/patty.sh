# patty: a PIN for the login and lock screens, which may also be drawn as a pattern.
#
#   patty set [user]     as root: ask a PIN twice and store its hash
#   patty clear [user]   as root: forget the PIN
#   patty kind [user]    "pattern" or "keypad": what a screen should draw
#   patty status [user]  whether a PIN is set and whether it is locked out
#   patty check          for pam_exec: the PIN on stdin, the user in PAM_USER
#
# A PIN is a pattern when every digit is a neighbour of the one before on the
# 1-9 grid (diagonals too) and none repeats; otherwise a screen shows a keypad.
# After five wrong PINs patty refuses for five minutes; the password still works.

dir=/var/lib/patty
tries=5
pause=300

# Usage and the user a command is about.
usage() {
  echo "usage: patty set|clear|kind|status [user] | patty check (from pam_exec)" >&2
  exit 2
}
target() {
  local user=${1:-${SUDO_USER:-$USER}}
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "patty: bad user name" >&2; exit 2; }
  id -u "$user" >/dev/null 2>&1 || { echo "patty: no user $user" >&2; exit 2; }
  printf '%s' "$user"
}

# The kind of a PIN, from its digits.
kind_of() {
  local pin=$1 i a b seen=""
  for ((i = 0; i < ${#pin}; i++)); do
    a=${pin:i:1}
    [[ $a == 0 || $seen == *"$a"* ]] && { echo keypad; return; }
    seen+=$a
    ((i == 0)) && continue
    b=${pin:i-1:1}
    local dr=$(( (a - 1) / 3 - (b - 1) / 3 )) dc=$(( (a - 1) % 3 - (b - 1) % 3 ))
    (( dr * dr <= 1 && dc * dc <= 1 )) || { echo keypad; return; }
  done
  echo pattern
}

# Root-only files the user may read (the PIN) or also write (the wrong-PIN count).
store() {
  local user=$1 file=$2 mode=$3
  chown root:root "$file"
  chmod 0600 "$file"
  setfacl -m "u:$user:$mode" "$file"
}

cmd_set() {
  ((EUID == 0)) || { echo "patty: run as root (sudo patty set)" >&2; exit 1; }
  local user pin again
  user=$(target "${1:-}")
  read -rsp "New PIN for $user (4-16 digits): " pin; echo
  [[ $pin =~ ^[0-9]{4,16}$ ]] || { echo "patty: 4 to 16 digits, nothing saved" >&2; exit 1; }
  read -rsp "Same PIN again: " again; echo
  [[ $pin == "$again" ]] || { echo "patty: the two differ, nothing saved" >&2; exit 1; }
  install -d -m 0755 "$dir"
  printf '%s %s\n' "$(kind_of "$pin")" "$(printf '%s' "$pin" | mkpasswd -m yescrypt --stdin)" > "$dir/$user"
  printf '0 0\n' > "$dir/$user.fails"
  store "$user" "$dir/$user" r
  store "$user" "$dir/$user.fails" rw
  echo "PIN saved for $user, drawn as a $(kind_of "$pin")"
}

cmd_clear() {
  ((EUID == 0)) || { echo "patty: run as root (sudo patty clear)" >&2; exit 1; }
  local user
  user=$(target "${1:-}")
  rm -f "$dir/$user" "$dir/$user.fails"
  echo "PIN cleared for $user"
}

cmd_kind() {
  local user
  user=$(target "${1:-}")
  [[ -r $dir/$user ]] || { echo none; exit 1; }
  cut -d' ' -f1 "$dir/$user"
}

cmd_status() {
  local user count until
  user=$(target "${1:-}")
  [[ -r $dir/$user ]] || { echo "$user: no PIN"; exit 1; }
  read -r count until < "$dir/$user.fails" 2>/dev/null || { count=0; until=0; }
  if ((until > EPOCHSECONDS)); then
    echo "$user: $(cut -d' ' -f1 "$dir/$user") PIN, locked for $((until - EPOCHSECONDS))s more"
  else
    echo "$user: $(cut -d' ' -f1 "$dir/$user") PIN, $count wrong of $tries"
  fi
}

# For pam_exec with expose_authtok: the typed PIN arrives on stdin.
cmd_check() {
  local user=${PAM_USER:-} pin="" hash count until
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ && -r $dir/$user ]] || exit 1
  IFS= read -r -d '' pin || true
  [[ $pin =~ ^[0-9]{4,16}$ ]] || exit 1
  read -r _ hash < "$dir/$user"
  read -r count until < "$dir/$user.fails" 2>/dev/null || { count=0; until=0; }
  ((until > EPOCHSECONDS)) && exit 1
  if [[ $(printf '%s' "$pin" | mkpasswd --stdin -S "${hash%\$*}") == "$hash" ]]; then
    printf '0 0\n' > "$dir/$user.fails"
    exit 0
  fi
  count=$((count + 1))
  if ((count >= tries)); then
    printf '0 %s\n' $((EPOCHSECONDS + pause)) > "$dir/$user.fails"
  else
    printf '%s 0\n' "$count" > "$dir/$user.fails"
  fi
  exit 1
}

case ${1:-} in
  set) cmd_set "${2:-}" ;;
  clear) cmd_clear "${2:-}" ;;
  kind) cmd_kind "${2:-}" ;;
  status) cmd_status "${2:-}" ;;
  check) cmd_check ;;
  *) usage ;;
esac
