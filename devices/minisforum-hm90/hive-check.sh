# Prints what each container can and cannot do; changes nothing.
set +e

echo "== host"
echo "io_uring_disabled: $(cat /proc/sys/kernel/io_uring_disabled)"
grep -E '^allowed-users' /etc/nix/nix.conf || true
echo "store: $(find /nix/store -mindepth 1 -maxdepth 1 | wc -l) paths"

probe='
  try() {
    timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null
    case $? in 0) r=open ;; 124) r=blocked ;; *) r=refused ;; esac
    printf "  %-22s %s\n" "$1:$2" "$r"
  }
  try 1.1.1.1 443
  try 10.231.0.1 22
  try 10.231.1.1 22
  try 192.168.6.10 22
  try 192.168.6.1 80
  try 10.99.0.2 22
  try 100.68.233.203 22
  try 10.231.0.2 3000
  try 10.231.1.2 8080
  if nix --extra-experimental-features nix-command store info --store daemon >/dev/null 2>&1
  then echo "  nix daemon: reachable"; else echo "  nix daemon: refused"; fi
  # Started by the container systemd, so it gets the container capabilities.
  if why=$(systemd-run --quiet --wait --pipe --collect ip link add hc0 type dummy 2>&1)
  then ip link del hc0; echo "  net admin: yes"; else echo "  net admin: no ($(echo "$why" | head -1))"; fi
  echo "  store: $(ls /nix/store | wc -l) paths, db: $(ls /nix/var/nix/db | wc -l) files, owner: $(stat -c %U /run/current-system/)"
  if a=$(getent hosts github.com 2>&1); then echo "  dns: ${a%% *}"
  else echo "  dns: failed ($?, $(type -P getent), $(grep -m1 nameserver /etc/resolv.conf))"; fi
  # AF_ALG needs no capability, so only the family filter can refuse it.
  perl=$(ls -d /nix/store/*-perl-5*/bin/perl 2>/dev/null | head -1)
  if [ -z "$perl" ]; then echo "  af_alg: untested (no perl)"
  elif why=$(systemd-run --quiet --wait --pipe --collect "$perl" -e "socket(my \$s, 38, 5, 0) or die qq(\$!)" 2>&1)
  then echo "  af_alg: allowed"; else echo "  af_alg: refused ($why)"; fi
  # Calls by number with arguments any user may pass, so only the call filter refuses them.
  for c in "keyctl 250, 0, -3" "userfaultfd 323, 1"; do
    [ -n "$perl" ] || break
    r=$(systemd-run --quiet --wait --pipe --collect "$perl" -e "syscall(${c#* }) < 0 and print qq(\$!)" 2>&1)
    echo "  ${c%% *}: ${r:-allowed}"
  done
  command -v ci-builders-test >/dev/null && ci-builders-test
  grep -E "^(CapBnd|NoNewPrivs)" /proc/1/status | sed "s/^/  /"
  echo "  failed units:"; systemctl --failed --no-legend --plain | sed "s/^/    /"
'

for f in /etc/nixos-containers/*.conf; do
  c=$(basename "$f" .conf)
  echo "== $c ($(systemctl is-active "container@$c"))"
  systemctl show "container@$c" -p MemoryCurrent -p MemoryMax -p TasksMax | sed 's/^/  /'
  timeout 300 nixos-container run "$c" -- bash -c "$probe"
  for u in $(systemctl -M "$c" --failed --no-legend --plain | cut -d' ' -f1); do
    echo "  log of $u:"
    journalctl -M "$c" -u "$u" -b -n 25 --no-pager -o cat | sed 's/^/    /'
  done
  echo "  last runs:"
  for u in gitea-backup radicle-sync radicle-backup attic-gc attic-backup; do
    systemctl -M "$c" show "$u" -p Result -p ExecMainStatus -p ExecMainExitTimestamp 2>/dev/null \
      | grep -q 'ExecMainExitTimestamp=.' || continue
    printf "    %-14s %s\n" "$u" "$(systemctl -M "$c" show "$u" -p Result -p ExecMainStatus -p ExecMainExitTimestamp \
      | cut -d= -f2- | tr '\n' ' ')"
  done
  echo "  exposure:"
  timeout 30 nixos-container run "$c" -- systemd-analyze security --no-pager 2>/dev/null \
    | grep -E '^(gitea|gitea-backup|atticd|attic-gc|attic-backup|cache-ui|caddy|rustfs)\.service' | sed 's/^/    /'
done

# Radicle in the gitea container: the node, its peers, and whether the network has
# the latest of each published repository.
if systemctl -M gitea is-active radicle-node >/dev/null 2>&1; then
  echo "== radicle"
  timeout 60 nixos-container run gitea -- bash -s <<'EOF'
j() { journalctl -u "$1" --since "$2" -o cat --no-pager; }
echo "  node: $(systemctl is-active radicle-node), up since $(systemctl show radicle-node -p ActiveEnterTimestamp --value)"
echo "  peers in the last hour: $(j radicle-node -1h | grep -c '(Outbound)') outbound, $(j radicle-node -1h | grep -c '(Inbound)') inbound"
echo "  sync: $(systemctl show radicle-sync -p Result --value), last at $(systemctl show radicle-sync -p ExecMainExitTimestamp --value)"
problems=$(j radicle-sync -15min | grep -E 'failed|waits for|rror' | sort -u | tail -5)
[ -n "$problems" ] && echo "$problems" | sed 's/^/  ! /'
for f in /var/lib/radicle-sync/public/*/*.json; do
  r=${f#/var/lib/radicle-sync/public/}; r=${r%.json}
  s=$(grep -oE '"status": *"synced"' "$f" | wc -l)
  b=$(grep -oE '"status": *"[a-z]*"' "$f" | grep -vc synced)
  u=$(grep -oE '"updated": *"[^"]*"' "$f" | cut -d'"' -f4)
  echo "  $r: $s synced, $b behind, $u"
done
EOF
fi
