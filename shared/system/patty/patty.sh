# patty: a pattern for the login and lock screens, drawn on a grid or typed on a
# keypad. `patty help` explains it all.

dir=/var/lib/patty
tries=5
pause=300

# Colours only on a terminal; the badge is the sudo prompt's fixed red.
if [[ -t 1 && -t 2 && -z ${NO_COLOR:-} ]]; then
  B=$'\e[1m' D=$'\e[2m' R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
  BADGE=$'\e[30;48;2;204;36;29m patty \e[0m'
else
  B="" D="" R="" G="" Y="" C="" N="" BADGE="patty:"
fi
say() { printf '%s %s\n' "$BADGE" "$*"; }
fail() { printf '%s %s%s%s\n' "$BADGE" "$R" "$*" "$N" >&2; exit "${code:-1}"; }

# The help page.
help() {
  cat <<EOF
$BADGE ${B}a pattern for the login and lock screens, drawn on a grid or typed${N}

${B}USAGE${N}
  patty ${C}<command>${N} ${D}[user]${N}

${B}COMMANDS${N}
  ${C}set${N} ${D}[user]${N}      ask a pattern twice and save it ${D}(as root: sudo patty set)${N}
  ${C}clear${N} ${D}[user]${N}    forget the pattern ${D}(as root)${N}
  ${C}status${N} ${D}[user]${N}   whether a pattern is set, and wrong tries or lockout
  ${C}kind${N} ${D}[user]${N}     ${D}grid${N} or ${D}keypad${N}: what a screen should show
  ${C}draw${N} ${D}<digits>${N}  show a pattern on the grid, or on a keypad
  ${C}check${N}            for PAM only: the pattern on stdin, the user in PAM_USER
  ${C}unlock${N}           for PAM only: open the keyrings at login
  ${C}help${N}             this page

${B}GRID OR KEYPAD${N}
  A pattern is 4 to 16 digits. It can be drawn on the ${G}grid${N} when each digit
  is next to the one before, diagonals too; a dot may come back, never twice in a row:

      ${C}1 2 3${N}      ${G}12369${N}  grid    ${Y}19283${N}  keypad
      ${C}4 5 6${N}      ${G}14789${N}  grid    ${Y}1593${N}   keypad  ${D}(9 to 3 skips 6)${N}
      ${C}7 8 9${N}      ${G}75321${N}  grid    ${Y}2580${N}   keypad  ${D}(0 is not on it)${N}

  Otherwise a screen shows a keypad. Either way the same digits are checked.

${B}SAFETY${N}
  After ${B}$tries${N} wrong patterns patty refuses for ${B}$((pause / 60)) minutes${N}; the password
  always still works. Only the login and lock screens take a pattern: never
  sudo, su, ssh or polkit.

${B}FILES${N}
  ${D}$dir/<user>${N}         the pattern's hash, readable by root and that user
  ${D}$dir/<user>.fails${N}   wrong tries and lockout
  ${D}$dir/<user>.kind${N}    grid or keypad, readable by everyone, for the login screen
  ${D}$dir/<user>.pat${N}     the keyrings' random key, locked with the pattern, root only
  ${D}$dir/<user>.pw${N}      the same key, locked with the login password, root only
  ${D}/run/patty/<user>${N}       the key in memory until shutdown, root only: opens the keyrings
EOF
}

# The user a command is about.
target() {
  local user=${1:-${SUDO_USER:-$USER}}
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || code=2 fail "bad user name: $user"
  id -u "$user" >/dev/null 2>&1 || code=2 fail "no user $user"
  printf '%s' "$user"
}

# Grid or keypad, from the digits of a pattern.
kind_of() {
  local pattern=$1 i a b
  for ((i = 0; i < ${#pattern}; i++)); do
    a=${pattern:i:1}
    [[ $a == 0 ]] && { echo keypad; return; }
    ((i == 0)) && continue
    b=${pattern:i-1:1}
    local dr=$(( (a - 1) / 3 - (b - 1) / 3 )) dc=$(( (a - 1) % 3 - (b - 1) % 3 ))
    (( a != b && dr * dr <= 1 && dc * dc <= 1 )) || { echo keypad; return; }
  done
  echo grid
}

# Root-only files the user may read (the pattern) or also write (the wrong tries).
store() {
  local user=$1 file=$2 mode=$3
  chown root:root "$file"
  chmod 0600 "$file"
  setfacl -m "u:$user:$mode" "$file"
}

cmd_set() {
  ((EUID == 0)) || fail "needs root: sudo patty set"
  local user pattern again kind uid path label asked="" key="" old="" new file salt
  local -a paths=() labels=() keys=()
  user=$(target "${1:-}")
  read -rsp "$BADGE new pattern for ${B}$user${N} ${D}(4-16 digits)${N}: " pattern; echo
  [[ $pattern =~ ^[0-9]{4,16}$ ]] || fail "4 to 16 digits only; nothing saved"
  read -rsp "$BADGE the same pattern again: " again; echo
  [[ $pattern == "$again" ]] || fail "the two patterns differ; nothing saved"

  # The keyrings' key: kept when this boot has it or the login password opens
  # it, else a new random one that the keyrings move to. What opens each
  # keyring is found before anything changes: no password, what this boot
  # remembers, or the login password, asked once.
  local kept="" d
  key=$(stashed "$user") || key=""
  if [[ -z $key && -r $dir/$user.pw ]]; then
    read -rsp "$BADGE login password of ${B}$user${N}, to keep the keyrings' key: " asked < /dev/tty; echo
    key=$(unseal "$user" "$asked") || fail "that is not the login password; nothing changed"
  fi
  if [[ -n $key && $(fmt_of "$user") == argon2 ]]; then new=$key kept=1
  else old=$key; new=$(head -c 32 /dev/urandom | base64 -w0); fi
  uid=$(id -u "$user")
  as_user() { runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" patty-keyring "$@"; }
  opens() { printf '%s\n%s\n' "$2" "$2" | as_user change "$1" 2>/dev/null; }
  [[ -n $kept || -S /run/user/$uid/bus ]] || fail "log in as $user first, so the keyrings can move to patty; nothing changed"
  if [[ -z $kept ]]; then
    local listed
    listed=$(as_user list 2>/dev/null) || fail "could not read the keyrings of $user; nothing changed"
    while IFS=$'\t' read -r path label; do
      [[ -n $path ]] || continue
      if opens "$path" ""; then key=""
      elif [[ -n $old ]] && opens "$path" "$old"; then key=$old
      else
        [[ -n $asked ]] || { read -rsp "$BADGE login password of ${B}$user${N}, to move the keyrings to patty: " asked < /dev/tty; echo; }
        if opens "$path" "$asked"; then key=$asked
        else
          file="$(getent passwd "$user" | cut -d: -f6)/.local/share/keyrings/$(printf '%s' "${path##*/}" | sed 's/_\([0-9a-f][0-9a-f]\)/\\x\1/g' | xargs -0 printf '%b').keyring"
          printf '%s %s\n' "$BADGE" "${R}keyring $label does not open with that password; nothing changed${N}" >&2
          printf '%s %s\n' "$BADGE" "to continue, move it away or remove it, then run sudo patty set again:" >&2
          printf '       %s\n' "mv '$file' '$file.old'" "rm '$file'" >&2
          exit 1
        fi
      fi
      paths+=("$path") labels+=("$label") keys+=("$key")
    done <<< "$listed"
  fi

  kind=$(kind_of "$pattern")
  salt=$(head -c 16 /dev/urandom | base64 -w0 | tr '+/' '-_')
  install -d -m 0755 "$dir"
  # The pattern's slow verifier, and the key locked with the pattern.
  d=$(derive "$pattern" "$salt")
  printf '%s argon2 %s %s %s\n' "$kind" "$salt" "$(printf '%s' "$d" | sha256sum | cut -c1-64)" "$(check_of "$new")" > "$dir/$user"
  (umask 077; wrap "$new" "$d" > "$dir/$user.pat")
  printf '0 0\n' > "$dir/$user.fails"
  store "$user" "$dir/$user" r
  store "$user" "$dir/$user.fails" rw
  # The lock screen checks as the user, so it reads the locked key too: the
  # verifier above already lets the user try patterns, so this adds nothing.
  store "$user" "$dir/$user.pat" r
  # Grid or keypad, apart from the hash: the greeter reads it before anyone signs in.
  printf '%s\n' "$kind" > "$dir/$user.kind"
  chown root:root "$dir/$user.kind"
  chmod 0644 "$dir/$user.kind"
  # The key locked with the login password: kept with the key, else made now or
  # at the next typed password.
  rm -f "$dir/$user.seal" "$dir/$user.key"
  if [[ -n $asked ]] && login_ok "$user" "$asked"; then seal "$user" "$new" "$asked"
  elif [[ -z $kept ]]; then rm -f "$dir/$user.pw"
  fi
  stash "$user" "$new"
  say "${G}saved${N} for ${B}$user${N}: screens will show a ${C}$kind${N}"
  [[ -n $kept ]] && say "keyrings keep opening with patty"
  local i
  for i in "${!paths[@]}"; do
    if printf '%s\n%s\n' "${keys[i]}" "$new" | as_user change "${paths[i]}" 2>/dev/null; then
      say "keyring ${G}${labels[i]}${N} now opens with patty"
    else
      say "${R}keyring ${labels[i]} not changed${N}"
    fi
  done
}

# The format of a saved pattern: argon2, or an older yescrypt hash.
fmt_of() {
  local _k fmt
  read -r _k fmt _ < "$dir/$1" 2>/dev/null || return 1
  [[ $fmt == argon2 ]] && echo argon2 || echo old
}

# The pattern stretched slowly (about a second): a key, as hex.
derive() {
  printf '%s' "$1" | argon2 "$2" -id -t 3 -m 18 -p 1 -l 32 -r
}

# A short fingerprint of the key, to tell a right one from a wrong decryption.
check_of() {
  printf '%s' "$1" | sha256sum | cut -c1-16
}

# The key encrypted with a secret (hex or a password), and back.
wrap() {
  printf '%s' "$1" | openssl enc -aes-256-cbc -pbkdf2 -iter 1 -salt -pass fd:3 3<<< "$2"
}
unwrap() {
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 1 -pass fd:3 3<<< "$2" < "$1" 2>/dev/null | tr -d "\0"
}

# Whether a password is the user's login password, from the shadow hash.
login_ok() {
  local hash
  hash=$(getent shadow "$1" | cut -d: -f2)
  [[ $hash == \$* && $(printf '%s' "$2" | mkpasswd --stdin -S "${hash%\$*}") == "$hash" ]]
}

# The key from typed digits, only if they are the pattern.
from_pattern() {
  local user=$1 _k fmt salt ver check key d
  read -r _k fmt salt ver check < "$dir/$user"
  if [[ $fmt != argon2 ]]; then
    # An older pattern: its hash only, no key; the digits open the keyrings.
    [[ $(printf '%s' "$2" | mkpasswd --stdin -S "${fmt%\$*}") == "$fmt" ]] && printf '%s' "$2"
    return
  fi
  d=$(derive "$2" "$salt") || return 1
  [[ $(printf '%s' "$d" | sha256sum | cut -c1-64) == "$ver" ]] || return 1
  key=$(unwrap "$dir/$user.pat" "$d") && [[ $(check_of "$key") == "$check" ]] && printf '%s' "$key"
}

# The key locked with the login password; root only.
seal() {
  (umask 077; printf '%s' "$2" | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass fd:3 3<<< "$3" > "$dir/$1.pw")
  chown root:root "$dir/$1.pw"
  chmod 0600 "$dir/$1.pw"
}

# The key back with the login password, only if it is the right key.
unseal() {
  local user=$1 key _k _f _s _v check
  [[ -r $dir/$user.pw ]] || return 1
  key=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass fd:3 3<<< "$2" < "$dir/$user.pw" 2>/dev/null | tr -d "\0")
  read -r _k _f _s _v check < "$dir/$user"
  [[ $(check_of "$key") == "$check" ]] && printf '%s' "$key"
}

# The key in memory (/run is RAM, gone at shutdown), root only: logins and
# password changes use it until the next boot.
stash() {
  install -d -m 0700 /run/patty
  (umask 077; printf '%s' "$2" > "/run/patty/$1")
}

# The key from memory, only if it is still the right one. An older pattern's
# memory holds the pattern itself.
stashed() {
  local key _k fmt _s _v check
  [[ -r /run/patty/$1 && -r $dir/$1 ]] || return 1
  key=$(< "/run/patty/$1")
  read -r _k fmt _s _v check < "$dir/$1"
  if [[ $fmt == argon2 ]]; then [[ $(check_of "$key") == "$check" ]] || return 1
  else [[ $(printf '%s' "$key" | mkpasswd --stdin -S "${fmt%\$*}") == "$fmt" ]] || return 1
  fi
  printf '%s' "$key"
}

cmd_clear() {
  ((EUID == 0)) || fail "needs root: sudo patty clear"
  local user
  user=$(target "${1:-}")
  [[ -e $dir/$user ]] || { say "${D}$user has no pattern; nothing to clear${N}"; return; }
  rm -f "$dir/$user" "$dir/$user.fails" "$dir/$user.kind" "$dir/$user.pat" "$dir/$user.pw" \
    "$dir/$user.seal" "$dir/$user.key" "/run/patty/$user"
  say "${Y}cleared${N} for ${B}$user${N}: only the password works now"
}

# The grid with the first k digits of seq drawn: dots 2 rows and 4 columns apart,
# lines between consecutive dots, the first dot green and the last one yellow.
render() {
  local seq=$1 k=$2 i r c a b ra ca rb cb mr mc ch out
  local -A cell=()
  for ((i = 1; i < k; i++)); do
    a=${seq:i-1:1} b=${seq:i:1}
    ra=$(( 2 * ((a - 1) / 3) )) ca=$(( 4 * ((a - 1) % 3) )) rb=$(( 2 * ((b - 1) / 3) )) cb=$(( 4 * ((b - 1) % 3) ))
    if ((ra == rb)); then
      for ((c = (ca < cb ? ca : cb) + 1; c < (ca > cb ? ca : cb); c++)); do cell[$ra,$c]="─"; done
    elif ((ca == cb)); then
      cell[$(( (ra + rb) / 2 )),$ca]="│"
    else
      mr=$(( (ra + rb) / 2 )) mc=$(( (ca + cb) / 2 ))
      if (( (rb - ra) * (cb - ca) > 0 )); then ch="╲"; else ch="╱"; fi
      [[ -n ${cell[$mr,$mc]:-} && ${cell[$mr,$mc]} != "$ch" ]] && ch="╳"
      cell[$mr,$mc]=$ch
    fi
  done
  for ((r = 0; r <= 4; r++)); do
    out="      "
    for ((c = 0; c <= 8; c++)); do
      if ((r % 2 == 0 && c % 4 == 0)); then
        a=$(( 3 * (r / 2) + c / 4 + 1 ))
        i=${seq:0:k}
        if [[ $a == "${seq:0:1}" ]]; then out+="${G}●${N}"
        elif [[ $a == "${seq:k-1:1}" ]]; then out+="${Y}●${N}"
        elif [[ $i == *"$a"* ]]; then out+="${C}●${N}"
        else out+="${D}·${N}"; fi
      elif [[ -n ${cell[$r,$c]:-} ]]; then out+="${C}${cell[$r,$c]}${N}"
      else out+=" "; fi
    done
    printf '%s\n' "$out"
  done
}

# Show any digits, step by step on a terminal. Never reads the stored pattern.
cmd_draw() {
  local seq=${1:-} k d out
  [[ $seq =~ ^[0-9]{1,16}$ ]] || code=2 fail "give digits to show, e.g. patty draw 12369"
  echo
  if [[ $(kind_of "$seq") == grid ]]; then
    if [[ -t 1 ]]; then
      for ((k = 1; k < ${#seq}; k++)); do render "$seq" "$k"; sleep 0.15; printf '\e[5A'; done
    fi
    render "$seq" "${#seq}"
    echo
    say "${B}$seq${N} is a ${G}grid${N} pattern: a screen can let you draw it"
  else
    for row in 123 456 789 " 0 "; do
      out="      "
      for ((k = 0; k < 3; k++)); do
        d=${row:k:1}
        if [[ $d == " " ]]; then out+="  "
        elif [[ $seq == *"$d"* ]]; then out+="${Y}${B}$d${N} "
        else out+="${D}$d${N} "; fi
      done
      printf '%s\n' "$out"
    done
    echo
    say "${B}$seq${N} is a ${Y}keypad${N} pattern: $(why_keypad "$seq")"
  fi
}

# Why digits can't go on the grid: the first step that breaks it.
why_keypad() {
  local seq=$1 i a b
  for ((i = 0; i < ${#seq}; i++)); do
    a=${seq:i:1}
    [[ $a == 0 ]] && { echo "0 is not on the grid"; return; }
    ((i == 0)) && continue
    b=${seq:i-1:1}
    local dr=$(( (a - 1) / 3 - (b - 1) / 3 )) dc=$(( (a - 1) % 3 - (b - 1) % 3 ))
    ((a == b)) && { echo "$a twice in a row"; return; }
    (( dr * dr <= 1 && dc * dc <= 1 )) || { echo "$b to $a is not a neighbour"; return; }
  done
}

# Plain on purpose: screens read this.
cmd_kind() {
  local user
  user=$(target "${1:-}")
  if [[ -r $dir/$user.kind ]]; then cat "$dir/$user.kind"
  elif [[ -r $dir/$user ]]; then cut -d' ' -f1 "$dir/$user"
  else echo none; exit 1; fi
}

cmd_status() {
  local user count until kind dots="" i
  user=$(target "${1:-}")
  [[ -r $dir/$user ]] || { say "${B}$user${N}: ${D}no pattern (set one with: sudo patty set)${N}"; exit 1; }
  kind=$(cut -d' ' -f1 "$dir/$user")
  read -r count until < "$dir/$user.fails" 2>/dev/null || { count=0; until=0; }
  if ((until > EPOCHSECONDS)); then
    say "${B}$user${N}: ${C}$kind${N} pattern, ${R}locked${N} for $((until - EPOCHSECONDS))s more ${D}(the password still works)${N}"
    return
  fi
  for ((i = 0; i < tries; i++)); do
    if ((i < count)); then dots+="${R}●${N}"; else dots+="${D}○${N}"; fi
  done
  say "${B}$user${N}: ${C}$kind${N} pattern, ${G}ready${N}  $dots ${D}$count of $tries wrong${N}"
}

# For pam_exec with expose_authtok: the typed pattern or password on stdin.
cmd_check() {
  local user=${PAM_USER:-} typed="" count until key
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ && -r $dir/$user ]] || exit 1
  IFS= read -r -d '' typed || true
  read -r count until < "$dir/$user.fails" 2>/dev/null || { count=0; until=0; }
  if [[ $typed =~ ^[0-9]{4,16}$ ]] && ((until <= EPOCHSECONDS)) && key=$(from_pattern "$user" "$typed"); then
    printf '0 0\n' > "$dir/$user.fails"
    # Only root keeps it: the lock screen checks as the user, whose session
    # keyrings are already open.
    ((EUID == 0)) && stash "$user" "$key"
    exit 0
  fi
  # Maybe the password: it opens the key for the keyrings, or after a password
  # change locks the key in memory with it anew. The password check decides the login.
  if ((EUID == 0)) && key=$(unseal "$user" "$typed"); then stash "$user" "$key"; exit 1; fi
  if [[ $(fmt_of "$user") == argon2 ]] && key=$(stashed "$user") && login_ok "$user" "$typed"; then
    seal "$user" "$key" "$typed"; exit 1
  fi
  [[ $typed =~ ^[0-9]{4,16}$ ]] && ((until <= EPOCHSECONDS)) || exit 1
  count=$((count + 1))
  if ((count >= tries)); then
    printf '0 %s\n' $((EPOCHSECONDS + pause)) > "$dir/$user.fails"
  else
    printf '%s 0\n' "$count" > "$dir/$user.fails"
  fi
  exit 1
}

# For pam_exec at session start: open the keyrings with the key in memory, in
# the background, once the session's keyring daemon is up.
cmd_unlock() {
  local user=${PAM_USER:-} uid
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ && -f /run/patty/$user ]] || exit 0
  uid=$(id -u "$user")
  setsid -f runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    patty-keyring unlock < "/run/patty/$user" > /dev/null 2>&1
}

case ${1:-help} in
  set) cmd_set "${2:-}" ;;
  unlock) cmd_unlock ;;
  clear) cmd_clear "${2:-}" ;;
  kind) cmd_kind "${2:-}" ;;
  draw) cmd_draw "${2:-}" ;;
  status) cmd_status "${2:-}" ;;
  check) cmd_check ;;
  help | -h | --help) help ;;
  *) help >&2; code=2 fail "unknown command: $1" ;;
esac
