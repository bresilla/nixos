# Prints what each container can and cannot do; changes nothing.
set +e

echo "== host"
echo "io_uring_disabled: $(cat /proc/sys/kernel/io_uring_disabled)"
grep -E '^allowed-users' /etc/nix/nix.conf || true

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
  if ip link add hc0 type dummy 2>/dev/null
  then ip link del hc0; echo "  net admin: yes"; else echo "  net admin: no"; fi
  grep -E "^(CapBnd|NoNewPrivs)" /proc/1/status | sed "s/^/  /"
  echo "  failed units:"; systemctl --failed --no-legend --plain | sed "s/^/    /"
'

for c in gitea cache; do
  echo "== $c ($(systemctl is-active "container@$c"))"
  systemctl show "container@$c" -p MemoryCurrent -p MemoryMax -p TasksMax | sed 's/^/  /'
  nixos-container run "$c" -- bash -c "$probe"
  for u in $(systemctl -M "$c" --failed --no-legend --plain | cut -d' ' -f1); do
    echo "  log of $u:"
    journalctl -M "$c" -u "$u" -b -n 25 --no-pager -o cat | sed 's/^/    /'
  done
  echo "  last runs:"
  for u in gitea-backup attic-gc attic-backup; do
    systemctl -M "$c" show "$u" -p Result -p ExecMainStatus -p ExecMainExitTimestamp 2>/dev/null \
      | grep -q 'ExecMainExitTimestamp=.' || continue
    printf "    %-14s %s\n" "$u" "$(systemctl -M "$c" show "$u" -p Result -p ExecMainStatus -p ExecMainExitTimestamp \
      | cut -d= -f2- | tr '\n' ' ')"
  done
  echo "  exposure:"
  nixos-container run "$c" -- systemd-analyze security --no-pager 2>/dev/null \
    | grep -E '^(gitea|gitea-backup|atticd|attic-gc|attic-backup|cache-ui|caddy)\.service' | sed 's/^/    /'
done
