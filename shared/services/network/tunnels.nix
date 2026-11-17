# Tunnels for single programs, not the whole machine: `tunnel mullvad <cmd>` and
# `tunnel tor <cmd>` run a command in a network namespace whose only way out is that
# tunnel, so nothing in it can leak past it and it stays offline when the tunnel is down.
# The Mullvad app stays for the whole machine; its account names the tunnel's own device.
{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.tunnels;
  user = config.bresilla.user.name;
  state = "/var/lib/tunnels/mullvad";
  api = "https://api.mullvad.net";
  # The link between the tor namespace and the host, where tor takes its traffic.
  torHost = "10.200.1.1";
  torPeer = "10.200.1.2";

  # Inside a namespace, names go only through its own resolver: nscd and resolved
  # would answer from the host's network, so neither is asked.
  nsswitch = pkgs.writeText "nsswitch.conf" ''
    passwd: files
    group: files
    shadow: files
    hosts: files dns
  '';

  # Run as the user, in the namespace: their own environment back, then the command.
  runner = pkgs.writeShellScript "tunnel-run" ''
    envf=$1; shift
    mapfile -d "" -t vars < "$envf"
    rm -f "$envf"
    exec env -i "''${vars[@]}" "$@"
  '';

  # As root, in the namespace's own mounts: hide the host's resolvers, then drop to the user.
  inner = pkgs.writeShellScript "tunnel-inner" ''
    set -eu
    uid=$1 gid=$2; shift 2
    for d in /run/nscd /run/systemd/resolve; do
      [ -d "$d" ] && ${pkgs.util-linux}/bin/mount -t tmpfs -o size=4k,mode=755 tmpfs "$d"
    done
    exec ${pkgs.util-linux}/bin/setpriv --reuid="$uid" --regid="$gid" --init-groups --inh-caps=-all --reset-env \
      -- ${runner} "$@"
  '';

  root = pkgs.writeShellApplication {
    name = "tunnel-root";
    runtimeInputs = with pkgs; [ iproute2 wireguard-tools curl jq coreutils systemd ];
    text = ''
      known() { case "$1" in ${lib.concatStringsSep "|" (lib.optional cfg.mullvad.enable "mullvad" ++ lib.optional cfg.tor.enable "tor")}) ;; *) echo "no tunnel named $1" >&2; exit 1 ;; esac; }
      relays() {
        if [ ! -s ${state}/relays.json ] || [ -n "$(find ${state}/relays.json -mmin +1440)" ]; then
          curl -fsS -m 30 ${api}/app/v1/relays -o ${state}/relays.json.new && mv ${state}/relays.json.new ${state}/relays.json
        fi
      }
      matching() {
        jq -r --arg l "$1" '.wireguard.relays[] | select(.active)
          | select($l == "any" or .hostname == $l or (.hostname | startswith($l + "-"))) | .hostname' ${state}/relays.json
      }
      token() {
        jq -n --rawfile a ${state}/account '{account_number: ($a | rtrimstr("\n"))}' \
          | curl -fsS -m 30 -X POST ${api}/auth/v1/token -H 'Content-Type: application/json' -d @- | jq -r .access_token
      }
      forget() {
        [ -s ${state}/device.json ] || return 0
        local t id
        t=$(token); id=$(jq -r .id ${state}/device.json)
        curl -fsS -m 30 -X DELETE "${api}/accounts/v1/devices/$id" -H @<(printf 'Authorization: Bearer %s\n' "$t") || true
        rm -f ${state}/device.json ${state}/key
      }

      cmd=''${1:-}; shift || true
      case "$cmd" in
        enter)
          name=$1 envf=$2; shift 2
          known "$name"
          [ -e "/run/netns/$name" ] || { echo "the $name tunnel is not up" >&2; exit 1; }
          exec ip netns exec "$name" ${inner} "$SUDO_UID" "$SUDO_GID" "$envf" "$@"
          ;;
        login)
          umask 077; mkdir -p ${state}
          tr -dc 0-9 | head -c 16 > ${state}/account.new
          [ "$(wc -c < ${state}/account.new)" -eq 16 ] || { echo "not a 16-digit account number" >&2; exit 1; }
          mv ${state}/account.new ${state}/account
          forget
          t=$(token)
          [ -n "$t" ] && [ "$t" != null ] || { echo "Mullvad refused the account" >&2; exit 1; }
          wg genkey > ${state}/key.new
          jq -n --arg k "$(wg pubkey < ${state}/key.new)" '{pubkey: $k, hijack_dns: false}' \
            | curl -fsS -m 30 -X POST ${api}/accounts/v1/devices -H 'Content-Type: application/json' \
                -H @<(printf 'Authorization: Bearer %s\n' "$t") -d @- > ${state}/device.json.new \
            || { rm -f ${state}/key.new ${state}/device.json.new; echo "no device made; at most 5 per account: mullvad account list-devices" >&2; exit 1; }
          mv ${state}/key.new ${state}/key; mv ${state}/device.json.new ${state}/device.json
          echo "this tunnel is Mullvad device \"$(jq -r .name ${state}/device.json)\""
          systemctl restart tunnel-mullvad
          ;;
        logout)
          forget; rm -f ${state}/account
          systemctl stop tunnel-mullvad
          ;;
        pick)
          loc=''${1:-any}
          [[ "$loc" =~ ^(any|[a-z]{2}(-[a-z]{3}(-wg-[0-9]{3})?)?)$ ]] || { echo "a location like se, se-got or se-got-wg-001" >&2; exit 1; }
          relays
          [ -n "$(matching "$loc")" ] || { echo "no active relay at $loc" >&2; exit 1; }
          echo "$loc" > ${state}/location
          systemctl restart tunnel-mullvad
          ;;
        up)
          [ -s ${state}/device.json ] || { echo "not logged in: tunnel mullvad login" >&2; exit 1; }
          relays
          host=$(matching "$(cat ${state}/location 2>/dev/null || echo any)" | shuf -n 1)
          [ -n "$host" ] || { echo "no active relay at the chosen location" >&2; exit 1; }
          relay=$(jq -c --arg h "$host" '.wireguard.relays[] | select(.hostname == $h)' ${state}/relays.json)
          ip netns add mullvad 2>/dev/null || true
          ip -n mullvad link set lo up
          ip -n mullvad link del wg-mullvad 2>/dev/null || true
          ip link del wg-mullvad 2>/dev/null || true
          # Made here, so its socket stays on the host's network, then moved in.
          ip link add wg-mullvad type wireguard
          wg set wg-mullvad private-key ${state}/key peer "$(jq -r .public_key <<< "$relay")" \
            endpoint "$(jq -r .ipv4_addr_in <<< "$relay"):51820" allowed-ips 0.0.0.0/0,::/0 persistent-keepalive 25
          ip link set wg-mullvad netns mullvad
          ip -n mullvad addr add "$(jq -r .ipv4_address ${state}/device.json)" dev wg-mullvad
          ip -n mullvad addr add "$(jq -r .ipv6_address ${state}/device.json)" dev wg-mullvad
          ip -n mullvad link set wg-mullvad up
          ip -n mullvad route add default dev wg-mullvad
          ip -n mullvad -6 route add default dev wg-mullvad
          echo "$host" > ${state}/relay
          ;;
        down)
          # The namespace stays: what runs in it is left without a network, not let out.
          ip -n mullvad link del wg-mullvad 2>/dev/null || true
          rm -f ${state}/relay
          ;;
        status)
          ${lib.optionalString cfg.mullvad.enable ''
            if [ -s ${state}/relay ] && [ -e /run/netns/mullvad ]; then
              shake=$(ip netns exec mullvad wg show wg-mullvad latest-handshakes | cut -f2)
              echo "mullvad  up    $(cat ${state}/relay)  $(jq -r .ipv4_address ${state}/device.json)  handshake $(( $(date +%s) - ''${shake:-0} ))s ago"
            elif [ -s ${state}/device.json ]; then echo "mullvad  down  at $(cat ${state}/location 2>/dev/null || echo any)"
            else echo "mullvad  not logged in: tunnel mullvad login"; fi
          ''}
          ${lib.optionalString cfg.tor.enable ''
            echo "tor      $(systemctl is-active tor)  $(systemctl is-active tunnel-tor >/dev/null && echo "namespace up" || echo "namespace down")"
          ''}
          ;;
        *) echo "tunnel-root: enter, login, logout, pick, up, down or status" >&2; exit 1 ;;
      esac
    '';
  };

  tunnel = pkgs.writeShellApplication {
    name = "tunnel";
    runtimeInputs = with pkgs; [ coreutils gnused ];
    text = ''
      root=/run/current-system/sw/bin/tunnel-root
      usage() {
        cat <<EOF
      tunnel                          status of every tunnel
      tunnel mullvad|tor [cmd ...]    run a command (or your shell) through that tunnel
      tunnel mullvad login [account]  give the tunnel its own Mullvad device; the app's account by default
      tunnel mullvad pick <location>  se, se-got, se-got-wg-001 or any
      tunnel mullvad up|down|logout
      A program that is already open (a browser, say) hands new windows to the open one,
      outside the tunnel: start it with its own profile, e.g. firefox --no-remote -P tunnel.
      EOF
      }
      name=''${1:-}; shift || true
      case "$name" in
        ""|status) exec sudo -n "$root" status ;;
        -h|--help|help) usage; exit 0 ;;
      esac
      case "$name:''${1:-}" in
        mullvad:login)
          account=''${2:-$(mullvad account get 2>/dev/null | sed -n 's/^Mullvad account: *//p')}
          [ -n "$account" ] || { echo "no account: log in the app (mullvad account login) or give the number" >&2; exit 1; }
          printf '%s' "$account" | sudo "$root" login; exit ;;
        mullvad:pick) exec sudo "$root" pick "''${2:-any}" ;;
        mullvad:up) exec sudo systemctl restart tunnel-mullvad ;;
        mullvad:down) exec sudo systemctl stop tunnel-mullvad ;;
        mullvad:logout) exec sudo "$root" logout ;;
      esac
      [ $# -gt 0 ] || set -- "''${SHELL:-bash}"
      envf=$(mktemp -p "''${XDG_RUNTIME_DIR:-/tmp}" tunnel-env.XXXXXX)
      TUNNEL=$name env -0 > "$envf"
      exec sudo -n "$root" enter "$name" "$envf" "$@"
    '';
  };
in
{
  options.bresilla.services.tunnels = {
    mullvad.enable = lib.mkEnableOption "the Mullvad tunnel for single programs (tunnel mullvad <cmd>)";
    tor.enable = lib.mkEnableOption "Tor, and its tunnel for single programs (tunnel tor <cmd>)";
  };

  config = lib.mkIf (cfg.mullvad.enable || cfg.tor.enable) (lib.mkMerge [
    {
      environment.systemPackages = [ root tunnel ];
      # Entering a tunnel and reading its status, without a password; the command runs as the user.
      security.sudo.extraRules = [{
        users = [ user ];
        commands = [
          { command = "/run/current-system/sw/bin/tunnel-root enter *"; options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/tunnel-root status"; options = [ "NOPASSWD" ]; }
        ];
      }];
    }

    (lib.mkIf cfg.mullvad.enable {
      environment.etc."netns/mullvad/resolv.conf".text = "nameserver 10.64.0.1\n";
      environment.etc."netns/mullvad/nsswitch.conf".source = nsswitch;
      systemd.tmpfiles.rules = [ "d ${state} 0700 root root -" ];
      systemd.services.tunnel-mullvad = {
        description = "Mullvad tunnel for single programs";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig.ConditionPathExists = "${state}/device.json";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${root}/bin/tunnel-root up";
          ExecStop = "${root}/bin/tunnel-root down";
          Restart = "on-failure";
          RestartSec = 30;
        };
      };
    })

    (lib.mkIf cfg.tor.enable {
      services.tor = {
        enable = true;
        client.enable = true;
        settings = {
          TransPort = [{ addr = torHost; port = 9040; }];
          DNSPort = [{ addr = torHost; port = 5353; }];
          AutomapHostsOnResolve = true;
          VirtualAddrNetworkIPv4 = "10.128.0.0/10";
        };
      };
      environment.systemPackages = [ pkgs.torsocks ];
      environment.etc."netns/tor/resolv.conf".text = "nameserver ${torHost}\n";
      environment.etc."netns/tor/nsswitch.conf".source = nsswitch;

      # The namespace and its link to the host, there before tor listens on it.
      systemd.services.tunnel-tor = {
        description = "Tor tunnel for single programs";
        before = [ "tor.service" ];
        requiredBy = [ "tor.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.iproute2 pkgs.procps ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          ip link del veth-tor 2>/dev/null || true
          ip netns add tor 2>/dev/null || true
          ip link add veth-tor type veth peer name eth0 netns tor
          ip addr add ${torHost}/30 dev veth-tor
          ip link set veth-tor up
          ip -n tor link set lo up
          ip -n tor addr add ${torPeer}/30 dev eth0
          ip -n tor link set eth0 up
          ip -n tor route add default via ${torHost}
          # Tor carries no IPv6 here; none to leak.
          ip netns exec tor sysctl -qw net.ipv6.conf.all.disable_ipv6=1
        '';
        preStop = "ip link del veth-tor 2>/dev/null || true";
      };
      networking.networkmanager.unmanaged = [ "interface-name:veth-tor" ];
      networking.firewall.interfaces.veth-tor = {
        allowedTCPPorts = [ 9040 ];
        allowedUDPPorts = [ 5353 ];
      };
      # Every TCP connection out of the namespace into tor, every lookup to its resolver,
      # nothing forwarded past the host. The ct mark is the one the Mullvad app lets
      # through its own firewall, so this keeps working while `mullvad connect` is on.
      networking.nftables.tables.tunnels = {
        family = "inet";
        content = ''
          chain tag {
            type filter hook prerouting priority mangle; policy accept;
            iifname "veth-tor" ct mark set 0x00000f41
          }
          chain divert {
            type nat hook prerouting priority dstnat; policy accept;
            iifname "veth-tor" udp dport 53 redirect to :5353
            iifname "veth-tor" meta l4proto tcp redirect to :9040
          }
          chain contain {
            type filter hook forward priority filter; policy accept;
            iifname "veth-tor" drop
            oifname "veth-tor" drop
          }
        '';
      };
    })
  ]);
}
