# Sets up, shows or removes this machine as a CI builder for build.bresilla.com.
# Any Linux with Nix (as a daemon) and systemd; on NixOS use the
# bresilla.nix.serveBuilds and ciBuilder.address options instead.
usage() {
  cat <<EOF
usage: sudo ci-builder setup --address 10.77.0.N
       sudo ci-builder status
       sudo ci-builder remove

setup: emulation for $PLATFORMS, a nix-ssh login only the ci container's key
may use, and this machine on hive's cicd0 tunnel at the given address.
EOF
  exit "${1:-0}"
}

action=${1:-}
[ "$action" = setup ] || [ "$action" = status ] || [ "$action" = remove ] || usage 1
shift
address=
while [ $# -gt 0 ]; do
  case $1 in
    --address) address=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    *) usage 1 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "run it with sudo" >&2; exit 1; }
[ -e /etc/NIXOS ] && { echo "this is NixOS: set bresilla.nix.serveBuilds and ciBuilder.address instead" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "needs systemd" >&2; exit 1; }

# Determinate's installer keeps local settings in nix.custom.conf.
nixconf=/etc/nix/nix.conf
[ -e /etc/nix/nix.custom.conf ] && nixconf=/etc/nix/nix.custom.conf
self=$(readlink -f "$0")
home=/var/lib/nix-ssh
unit=/etc/systemd/system/nix-ci-cicd0.service

drop_block() {
  [ -e "$nixconf" ] && sed -i '/^# nix-ci-builder begin$/,/^# nix-ci-builder end$/d' "$nixconf"
  return 0
}

if [ "$action" = status ]; then
  echo "emulation:"
  for p in $PLATFORMS; do
    printf '  %-14s %s\n' "$p" "$(head -1 "/proc/sys/fs/binfmt_misc/nix-ci-$p" 2>/dev/null || echo "not registered")"
  done
  echo "nix: $(grep -A3 '^# nix-ci-builder begin' "$nixconf" 2>/dev/null | grep extra-platforms || echo "not set up")"
  echo "login: $(grep -c ci-ci-builder "$home/.ssh/authorized_keys" 2>/dev/null || echo 0) ci key(s) for nix-ssh"
  echo "tunnel: $(systemctl is-active nix-ci-cicd0.service 2>/dev/null)"
  wg show cicd0 latest-handshakes 2>/dev/null | sed 's/^/  handshake: /'
  exit 0
fi

if [ "$action" = remove ]; then
  systemctl disable --now nix-ci-cicd0.service 2>/dev/null || true
  rm -f "$unit" /etc/wireguard/cicd0.conf /etc/binfmt.d/nix-ci-builder.conf /nix/var/nix/gcroots/nix-ci-builder
  for p in $PLATFORMS; do [ -e "/proc/sys/fs/binfmt_misc/nix-ci-$p" ] && echo -1 > "/proc/sys/fs/binfmt_misc/nix-ci-$p"; done
  drop_block
  systemctl daemon-reload
  systemctl restart nix-daemon.service 2>/dev/null || true
  rm -f "$home/.ssh/authorized_keys"
  echo "removed; the nix-ssh user and /etc/wireguard/cicd0.key are kept"
  exit 0
fi

[[ $address =~ ^10\.77\.0\.([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -ge 2 ] && [ "${BASH_REMATCH[1]}" -le 254 ] \
  || { echo "--address must be 10.77.0.N (pick one hive's cicd0 does not use yet)" >&2; exit 1; }

# Everything below runs from the Nix store; this root keeps it there.
nix-store --add-root /nix/var/nix/gcroots/nix-ci-builder -r "$self" >/dev/null

echo "1/4 emulation for $PLATFORMS"
install -D -m 0644 "$BINFMT" /etc/binfmt.d/nix-ci-builder.conf
for p in $PLATFORMS; do [ -e "/proc/sys/fs/binfmt_misc/nix-ci-$p" ] && echo -1 > "/proc/sys/fs/binfmt_misc/nix-ci-$p"; done
systemctl restart systemd-binfmt.service

echo "2/4 nix: extra platforms, nix-ssh trusted"
drop_block
cat >> "$nixconf" <<EOF
# nix-ci-builder begin
extra-platforms = $PLATFORMS
extra-trusted-users = nix-ssh
# nix-ci-builder end
EOF
systemctl restart nix-daemon.service

echo "3/4 nix-ssh: only the ci container's key, only nix-daemon --stdio"
id nix-ssh >/dev/null 2>&1 || useradd --system --home-dir "$home" --create-home --shell /bin/sh nix-ssh
daemon=$(command -v nix-daemon || echo /nix/var/nix/profiles/default/bin/nix-daemon)
install -d -m 0700 -o nix-ssh -g "$(id -gn nix-ssh)" "$home/.ssh"
echo "restrict,command=\"$daemon --stdio\" $CI_KEY" > "$home/.ssh/authorized_keys"
chown nix-ssh "$home/.ssh/authorized_keys"
chmod 0600 "$home/.ssh/authorized_keys"
systemctl is-active -q sshd.service || systemctl is-active -q ssh.service \
  || echo "   warning: no running sshd; install and start openssh-server"

echo "4/4 cicd0 tunnel to hive as $address"
install -d -m 0700 /etc/wireguard
[ -s /etc/wireguard/cicd0.key ] || (umask 077; wg genkey > /etc/wireguard/cicd0.key)
(umask 077; cat > /etc/wireguard/cicd0.conf <<EOF
[Interface]
Address = $address/32
PrivateKey = $(cat /etc/wireguard/cicd0.key)
MTU = 1412

[Peer]
PublicKey = $HIVE_KEY
Endpoint = $HIVE_ENDPOINT
AllowedIPs = $HIVE_ADDRESS/32
PersistentKeepalive = 25
EOF
)
cat > "$unit" <<EOF
[Unit]
Description=cicd0 tunnel to hive for CI builds
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=$TOOLS_PATH:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$WG_QUICK up /etc/wireguard/cicd0.conf
ExecStop=$WG_QUICK down /etc/wireguard/cicd0.conf

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable nix-ci-cicd0.service >/dev/null 2>&1
systemctl restart nix-ci-cicd0.service

# Hive reaches SSH here over the tunnel; open it in the firewalls that are common.
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow in on cicd0 to any port 22 proto tcp >/dev/null
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --zone=trusted --add-interface=cicd0 >/dev/null && firewall-cmd --reload >/dev/null
fi

host=$(hostname -s)
cat <<EOF

Done. Two steps left, both for hive:
  1. Add this peer to hive's cicd0 (devices/minisforum-hm90/services/cache.nix), then update hive:
       { name = "$host"; publicKey = "$(wg pubkey < /etc/wireguard/cicd0.key)"; allowedIPs = [ "$address/32" ]; }
  2. On https://build.bresilla.com/-/builders add a machine: name $host, address $address,
     then "Fetch host key" and pick the systems it builds.
Check this side any time with: sudo ci-builder status
EOF
