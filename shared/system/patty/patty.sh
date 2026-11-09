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
  ${C}help${N}             this page

${B}GRID OR KEYPAD${N}
  A pattern is 4 to 16 digits. It can be drawn on the ${G}grid${N} when each digit
  is next to the one before, diagonals too, and no digit repeats:

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
  local pattern=$1 i a b seen=""
  for ((i = 0; i < ${#pattern}; i++)); do
    a=${pattern:i:1}
    [[ $a == 0 || $seen == *"$a"* ]] && { echo keypad; return; }
    seen+=$a
    ((i == 0)) && continue
    b=${pattern:i-1:1}
    local dr=$(( (a - 1) / 3 - (b - 1) / 3 )) dc=$(( (a - 1) % 3 - (b - 1) % 3 ))
    (( dr * dr <= 1 && dc * dc <= 1 )) || { echo keypad; return; }
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
  local user pattern again kind
  user=$(target "${1:-}")
  read -rsp "$BADGE new pattern for ${B}$user${N} ${D}(4-16 digits)${N}: " pattern; echo
  [[ $pattern =~ ^[0-9]{4,16}$ ]] || fail "4 to 16 digits only; nothing saved"
  read -rsp "$BADGE the same pattern again: " again; echo
  [[ $pattern == "$again" ]] || fail "the two patterns differ; nothing saved"
  kind=$(kind_of "$pattern")
  install -d -m 0755 "$dir"
  printf '%s %s\n' "$kind" "$(printf '%s' "$pattern" | mkpasswd -m yescrypt --stdin)" > "$dir/$user"
  printf '0 0\n' > "$dir/$user.fails"
  store "$user" "$dir/$user" r
  store "$user" "$dir/$user.fails" rw
  # Grid or keypad, apart from the hash: the greeter reads it before anyone signs in.
  printf '%s\n' "$kind" > "$dir/$user.kind"
  chown root:root "$dir/$user.kind"
  chmod 0644 "$dir/$user.kind"
  say "${G}saved${N} for ${B}$user${N}: screens will show a ${C}$kind${N}"
  rekey "$user" "$pattern"
}

# The login keyring takes the pattern as its password, so a pattern login opens it.
rekey() {
  local user=$1 pattern=$2 uid old
  uid=$(id -u "$user")
  [[ -S /run/user/$uid/bus ]] || { say "${D}$user is not logged in; keyring left as it is${N}"; return; }
  read -rsp "$BADGE current keyring password ${D}(Enter to skip)${N}: " old; echo
  [[ -n $old ]] || { say "${D}keyring left as it is${N}"; return; }
  if printf '%s\n%s\n' "$old" "$pattern" |
    runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" patty-keyring 2>/dev/null; then
    say "${G}keyring${N} now opens with the pattern"
  else
    say "${R}keyring not changed${N}: wrong current password?"
  fi
}

cmd_clear() {
  ((EUID == 0)) || fail "needs root: sudo patty clear"
  local user
  user=$(target "${1:-}")
  [[ -e $dir/$user ]] || { say "${D}$user has no pattern; nothing to clear${N}"; return; }
  rm -f "$dir/$user" "$dir/$user.fails" "$dir/$user.kind"
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
  local seq=$1 i a b seen=""
  for ((i = 0; i < ${#seq}; i++)); do
    a=${seq:i:1}
    [[ $a == 0 ]] && { echo "0 is not on the grid"; return; }
    [[ $seen == *"$a"* ]] && { echo "$a is used twice"; return; }
    seen+=$a
    ((i == 0)) && continue
    b=${seq:i-1:1}
    local dr=$(( (a - 1) / 3 - (b - 1) / 3 )) dc=$(( (a - 1) % 3 - (b - 1) % 3 ))
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

# For pam_exec with expose_authtok: the typed pattern arrives on stdin.
cmd_check() {
  local user=${PAM_USER:-} pattern="" hash count until
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ && -r $dir/$user ]] || exit 1
  IFS= read -r -d '' pattern || true
  [[ $pattern =~ ^[0-9]{4,16}$ ]] || exit 1
  read -r _ hash < "$dir/$user"
  read -r count until < "$dir/$user.fails" 2>/dev/null || { count=0; until=0; }
  ((until > EPOCHSECONDS)) && exit 1
  if [[ $(printf '%s' "$pattern" | mkpasswd --stdin -S "${hash%\$*}") == "$hash" ]]; then
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

case ${1:-help} in
  set) cmd_set "${2:-}" ;;
  clear) cmd_clear "${2:-}" ;;
  kind) cmd_kind "${2:-}" ;;
  draw) cmd_draw "${2:-}" ;;
  status) cmd_status "${2:-}" ;;
  check) cmd_check ;;
  help | -h | --help) help ;;
  *) help >&2; code=2 fail "unknown command: $1" ;;
esac
