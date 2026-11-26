# Tunnels for single programs, not the whole machine: `tunnel mullvad -- <cmd>` and
# `tunnel tor -- <cmd>` run a command in a network namespace whose only way out is that
# tunnel, so nothing in it can leak past it and it stays offline when the tunnel is down.
# The Mullvad app stays for the whole machine; its account names the tunnel's own device.
{ config, lib, pkgs, termworks, ... }:

let
  cfg = config.bresilla.services.tunnels;
  user = config.bresilla.user.name;
  state = "/var/lib/tunnels/mullvad";
  api = "https://api.mullvad.net";
  # The link between the tor namespace and the host, where tor takes its traffic.
  torHost = "10.200.1.1";
  torPeer = "10.200.1.2";
  # Teleport: the namespace's link, the routing table only it uses, and while the flag is
  # there, WiFiman's next connection goes to the namespace instead of the whole machine.
  teleportHost = "10.201.0.1";
  teleportPeer = "10.201.0.2";
  teleportNet = "10.201.0.0/30";
  teleportTable = toString cfg.teleport.table;
  teleportRun = "/run/tunnels/teleport";
  teleportFlag = "/run/tunnels/teleport.ns";
  # The university's FortiVPN: openfortivpn inside the namespace, which reaches only the
  # gateway past its link; drives are served from inside and mounted on the host.
  uniHost = "10.202.0.1";
  uniPeer = "10.202.0.2";
  uniState = "/var/lib/tunnels/uni";
  uniRun = "/run/tunnels/uni";
  uniProxy = 8443;

  # Inside a namespace, names go only through its own resolver: nscd and resolved
  # would answer from the host's network, so neither is asked.
  nsswitch = pkgs.writeText "nsswitch.conf" ''
    passwd: files
    group: files
    shadow: files
    hosts: files dns
  '';

  # In a namespace's own mounts, as root: hide the host's resolvers, then run the command.
  hideResolvers = pkgs.writeShellScript "tunnel-hide-resolvers" ''
    [ -d /run/nscd ] && ${pkgs.util-linux}/bin/mount -t tmpfs -o size=4k,mode=755 tmpfs /run/nscd
    for s in /run/systemd/resolve/io.systemd.Resolve /run/systemd/resolve/io.systemd.Resolve.Monitor; do
      [ -S "$s" ] && ${pkgs.util-linux}/bin/mount --bind /dev/null "$s"
    done
    exec "$@"
  '';

  # Run as the user, in the namespace: their own environment back, then the command.
  runner = pkgs.writeShellScript "tunnel-run" ''
    envf=$1; shift
    mapfile -d "" -t vars < "$envf"
    ${pkgs.coreutils}/bin/rm -f "$envf"
    exec ${pkgs.coreutils}/bin/env -i "''${vars[@]}" "$@"
  '';

  # As root, in the namespace's own mounts: hide the host's resolvers, then drop to the user.
  inner = pkgs.writeShellScript "tunnel-inner" ''
    set -eu
    uid=$1 gid=$2; shift 2
    [ -d /run/nscd ] && ${pkgs.util-linux}/bin/mount -t tmpfs -o size=4k,mode=755 tmpfs /run/nscd
    # Only resolved's sockets: its directory also holds the resolv.conf the namespace's own covers.
    for s in /run/systemd/resolve/io.systemd.Resolve /run/systemd/resolve/io.systemd.Resolve.Monitor; do
      [ -S "$s" ] && ${pkgs.util-linux}/bin/mount --bind /dev/null "$s"
    done
    # Flatpak sandboxes read a copy its host-side helper makes of the host's resolver.
    f=/run/user/$uid/.flatpak-helper/monitor/resolv.conf
    [ -f "$f" ] && ${pkgs.util-linux}/bin/mount --bind /etc/resolv.conf "$f"
    exec ${pkgs.util-linux}/bin/setpriv --reuid="$uid" --regid="$gid" --init-groups --inh-caps=-all --reset-env \
      -- ${runner} "$@"
  '';

  root = pkgs.writeShellApplication {
    name = "tunnel-root";
    runtimeInputs = with pkgs; [ iproute2 wireguard-tools curl jq coreutils systemd gawk findutils glibc.getent nftables gnused ];
    text = ''
      known() { case "$1" in ${lib.concatStringsSep "|" (lib.optional cfg.mullvad.enable "mullvad" ++ lib.optional cfg.tor.enable "tor" ++ lib.optional cfg.teleport.enable "teleport" ++ lib.optional cfg.uni.enable "uni")}) ;; *) echo "no tunnel named $1" >&2; exit 1 ;; esac; }
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
          [ -s ${state}/device.json ] || { echo "not logged in: tunnel mullvad --login" >&2; exit 1; }
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
        # For the user, through the service, so it stays the one place that connects.
        connect) systemctl restart tunnel-mullvad ;;
        disconnect) systemctl stop tunnel-mullvad ;;
        status)
          ${lib.optionalString cfg.mullvad.enable ''
            if [ -s ${state}/relay ] && [ -e /run/netns/mullvad ]; then
              shake=$(ip netns exec mullvad wg show wg-mullvad latest-handshakes | cut -f2)
              echo "mullvad  up    $(cat ${state}/relay)  $(jq -r .ipv4_address ${state}/device.json)  handshake $(( $(date +%s) - ''${shake:-0} ))s ago"
            elif [ -s ${state}/device.json ]; then echo "mullvad  down  at $(cat ${state}/location 2>/dev/null || echo any)"
            else echo "mullvad  not logged in: tunnel mullvad --login"; fi
          ''}
          ${lib.optionalString cfg.tor.enable ''
            echo "tor      $(systemctl is-active tor)  $(systemctl is-active tunnel-tor >/dev/null && echo "namespace up" || echo "namespace down")"
          ''}
          ${lib.optionalString cfg.uni.enable ''
            if ip -n uni -4 -o addr show dev ppp0 2>/dev/null | grep -q inet; then
              echo "uni      up    $(sed -n 's/^host *= *//p' ${uniState}/config)  $(ip -n uni -4 -o addr show dev ppp0 | awk '{print $4}')  dns $(awk '/^nameserver/{print $2}' ${uniRun}/resolv.conf | xargs)"
            elif [ -s ${uniState}/config ]; then echo "uni      down  $(systemctl is-active tunnel-uni-vpn)"
            else echo "uni      not logged in: tunnel uni --login"; fi
          ''}
          ${lib.optionalString cfg.teleport.enable ''
            if ip -o route show table ${teleportTable} default | grep -q wgwfm; then
              echo "teleport up    $(ip -o route show table ${teleportTable} default | awk '{print $3}')  dns $(awk '/^nameserver/{print $2}' ${teleportRun}/resolv.conf | xargs)"
            else echo "teleport down"; fi
          ''}
          ;;
        teleport)
          case ''${1:-} in
            on)
              mkdir -p ${teleportRun}; touch ${teleportFlag}
              # The namespace's way in, in case something flushed it since boot.
              ip route replace ${teleportNet} dev tph table ${teleportTable}
              [ -n "$(ip rule show pref 100)" ] || ip rule add pref 100 from ${teleportPeer} lookup ${teleportTable}
              [ -n "$(ip rule show pref 101)" ] || ip rule add pref 101 from ${teleportPeer} unreachable
              ;;
            off) rm -f ${teleportFlag} ;;
            *) echo "tunnel-root teleport on|off" >&2; exit 1 ;;
          esac
          ;;
        uni)
          case ''${1:-} in
            login)
              # Three lines on stdin: the gateway (host or host:port), the username, the password.
              umask 077; mkdir -p ${uniState}
              IFS= read -r gw || true; IFS= read -r name || true; IFS= read -r pass || true
              ${lib.optionalString (cfg.uni.gateway != null) ''[ -n "$gw" ] || gw=${lib.escapeShellArg cfg.uni.gateway}''}
              ${lib.optionalString (cfg.uni.credentials != null) ''
                if [ -z "$pass" ] && [ -r ${cfg.uni.credentials} ]; then
                  [ -n "$name" ] || name=$(sed -n 's/^username=//p' ${cfg.uni.credentials})
                  pass=$(sed -n 's/^password=//p' ${cfg.uni.credentials})
                fi
              ''}
              [ -n "$gw" ] && [ -n "$name" ] && [ -n "$pass" ] || { echo "gateway, username and password are all needed" >&2; exit 1; }
              host=''${gw%%:*}; port=443
              [ "$host" != "$gw" ] && port=''${gw##*:}
              [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$port" =~ ^[0-9]+$ ]] || { echo "not a gateway: $gw" >&2; exit 1; }
              printf 'host = %s\nport = %s\nusername = %s\npassword = %s\n' "$host" "$port" "$name" "$pass" > ${uniState}/config.new
              # A certificate trusted before, or the configured one, stays trusted.
              trusted=$(sed -n 's/^trusted-cert *= *//p' ${uniState}/config 2>/dev/null || true)
              ${lib.optionalString (cfg.uni.trustedCert != null) ''[ -n "$trusted" ] || trusted=${cfg.uni.trustedCert}''}
              [ -z "$trusted" ] || echo "trusted-cert = $trusted" >> ${uniState}/config.new
              mv ${uniState}/config.new ${uniState}/config
              systemctl restart tunnel-uni-proxy tunnel-uni-vpn
              ;;
            trust)
              [[ "''${2:-}" =~ ^[0-9a-f]{64}$ ]] || { echo "a sha256 digest, as openfortivpn prints it" >&2; exit 1; }
              sed -i '/^trusted-cert/d' ${uniState}/config
              echo "trusted-cert = $2" >> ${uniState}/config
              systemctl restart tunnel-uni-proxy tunnel-uni-vpn
              ;;
            logout) systemctl stop tunnel-uni-vpn tunnel-uni-proxy; rm -f ${uniState}/config ;;
            connect) systemctl restart tunnel-uni-vpn ;;
            disconnect) systemctl stop tunnel-uni-vpn ;;
            # Before each connection: inside, the gateway's name is the host's proxy on the link.
            gateway)
              host=$(sed -n 's/^host *= *//p' ${uniState}/config)
              printf '127.0.0.1 localhost\n::1 localhost\n${uniHost} %s\n' "$host" > ${uniRun}/hosts
              ;;
            log) exec journalctl -u tunnel-uni-vpn -n "''${2:-40}" --no-pager ;;
            *) echo "tunnel-root uni login|trust|logout|connect|disconnect|gateway|log" >&2; exit 1 ;;
          esac
          ;;
        *) echo "tunnel-root: enter, login, logout, pick, up, down, connect, disconnect, teleport, uni or status" >&2; exit 1 ;;
      esac
    '';
  };

  # The user's side, in oslo: its argc comments are the flags and the help.
  tunnel = pkgs.writeTextFile {
    name = "tunnel";
    executable = true;
    destination = "/bin/tunnel";
    text = builtins.replaceStrings [ "@oslo@" "@path@" ] [
      "${termworks.oslo.packages.${pkgs.stdenv.hostPlatform.system}.oslo}/bin/oslo"
      (lib.makeBinPath [ pkgs.coreutils pkgs.gnused ])
    ] (builtins.readFile ./tunnel.oslo);
  };
in
{
  options.bresilla.services.tunnels = {
    mullvad.enable = lib.mkEnableOption "the Mullvad tunnel for single programs (tunnel mullvad <cmd>)";
    tor.enable = lib.mkEnableOption "Tor, and its tunnel for single programs (tunnel tor <cmd>)";
    teleport.enable = lib.mkEnableOption "WiFiman Teleport for single programs (tunnel teleport <cmd>)";
    uni.enable = lib.mkEnableOption "the university's FortiVPN for single programs (tunnel uni <cmd>)";
    uni.drives = lib.mkOption {
      default = { };
      example = { M = { remote = "M:"; port = 8101; }; };
      description = ''
        Drives reached only through the uni tunnel, mounted at ~/<name>: rclone serves the
        remote from inside the tunnel and mounts it here. A drive whose remote is not in
        rclone's config is skipped.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options.remote = lib.mkOption {
          type = lib.types.str;
          description = "The rclone remote: a configured one (M:) or a connection string (:smb,host=…:share/path).";
        };
        options.port = lib.mkOption { type = lib.types.port; description = "Its WebDAV port on the tunnel's link."; };
        options.path = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Where it mounts; ~/<name> by default."; };
      });
    };
    uni.gateway = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "vpn.example.edu:443";
      description = "The FortiVPN gateway `tunnel uni --login` uses when none is typed.";
    };
    uni.trustedCert = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[0-9a-f]{64}");
      default = null;
      description = "The gateway certificate's sha256 digest, for a gateway whose chain does not validate.";
    };
    uni.credentials = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/wur/access.creds";
      description = ''
        A CIFS credentials file (username=, password=, domain=): the VPN logs in with it
        when no password was given, and SMB drives use it.
      '';
    };
    teleport.table = lib.mkOption {
      type = lib.types.int;
      default = 51821;
      internal = true;
      description = "Routing table only the teleport namespace uses; WiFiman's wg-quick fills it.";
    };
  };

  config = lib.mkIf (cfg.mullvad.enable || cfg.tor.enable || cfg.teleport.enable || cfg.uni.enable) (lib.mkMerge [
    {
      environment.systemPackages = [ root tunnel ];
      # Everything tunnel-root does, without a password: it only touches the tunnels, and
      # what runs in one runs as the user.
      security.sudo.extraRules = [{
        users = [ user ];
        commands = [{ command = "/run/current-system/sw/bin/tunnel-root"; options = [ "NOPASSWD" ]; }];
      }];
    }

    (lib.mkIf cfg.teleport.enable {
      assertions = [{
        assertion = config.bresilla.services.wifiman.enable;
        message = "tunnels.teleport needs bresilla.services.wifiman";
      }];
      environment.etc."netns/teleport/resolv.conf".source = "${teleportRun}/resolv.conf";
      environment.etc."netns/teleport/nsswitch.conf".source = nsswitch;
      # The namespace, its link and its routing are always there; only Teleport fills the
      # table, so without it the namespace's traffic finds no way out.
      systemd.services.tunnel-teleport = {
        description = "WiFiman Teleport tunnel for single programs";
        before = [ "wifiman-desktop.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.iproute2 pkgs.procps ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          mkdir -p ${teleportRun}
          echo "# Teleport is down" > ${teleportRun}/resolv.conf
          ip link del tph 2>/dev/null || true
          ip netns add teleport 2>/dev/null || true
          ip link add tph type veth peer name tpn netns teleport
          ip addr add ${teleportHost}/30 dev tph
          ip link set tph up
          ip -n teleport link set lo up
          ip -n teleport addr add ${teleportPeer}/30 dev tpn
          ip -n teleport link set tpn up
          ip -n teleport route add default via ${teleportHost}
          ip netns exec teleport sysctl -qw net.ipv6.conf.all.disable_ipv6=1
          sysctl -qw net.ipv4.conf.tph.forwarding=1
          ip route replace ${teleportNet} dev tph table ${teleportTable}
          ip rule del pref 100 2>/dev/null || true
          ip rule del pref 101 2>/dev/null || true
          ip rule add pref 100 from ${teleportPeer} lookup ${teleportTable}
          ip rule add pref 101 from ${teleportPeer} unreachable
        '';
        preStop = ''
          ip rule del pref 100 2>/dev/null || true
          ip rule del pref 101 2>/dev/null || true
          ip link del tph 2>/dev/null || true
        '';
      };
      networking.networkmanager.unmanaged = [ "interface-name:tph" ];
      # networkd otherwise drops the namespace's rules and table when it reconfigures.
      systemd.network.config.networkConfig = {
        ManageForeignRoutingPolicyRules = false;
        ManageForeignRoutes = false;
      };
      # Out through Teleport as its own address; nothing else is forwarded from here.
      networking.nftables.tables.teleport = {
        family = "ip";
        content = ''
          chain outbound {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "wgwfm*" ip saddr ${teleportPeer} masquerade
          }
          chain contain {
            type filter hook forward priority filter; policy accept;
            iifname "tph" oifname != "wgwfm*" drop
          }
        '';
      };
    })

    (lib.mkIf cfg.uni.enable {
      environment.systemPackages = [ pkgs.openfortivpn ];
      boot.kernelModules = [ "ppp_generic" "ppp_async" ];
      # openfortivpn writes the VPN's resolvers into this file in place; the gateway's
      # address comes from the hosts file, as nothing else resolves before the VPN is up.
      environment.etc."netns/uni/resolv.conf".source = "${uniRun}/resolv.conf";
      environment.etc."netns/uni/hosts".source = "${uniRun}/hosts";
      environment.etc."netns/uni/nsswitch.conf".source = nsswitch;
      systemd.tmpfiles.rules = [ "d ${uniState} 0700 root root -" ]
        ++ lib.mapAttrsToList (name: drive: "d ${drive.path} 0755 ${user} users -")
          (lib.filterAttrs (_: drive: drive.path != null) cfg.uni.drives);

      # The namespace and its link to the host, with no route out: without the VPN it reaches
      # only the proxy to the gateway on the host's end of the link.
      systemd.services.tunnel-uni = {
        description = "University tunnel for single programs";
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.iproute2 pkgs.procps ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          mkdir -p ${uniRun}
          echo "# the uni VPN is down" > ${uniRun}/resolv.conf
          printf '127.0.0.1 localhost\n::1 localhost\n' > ${uniRun}/hosts
          ip link del uph 2>/dev/null || true
          ip netns add uni 2>/dev/null || true
          ip link add uph type veth peer name upn netns uni
          ip addr add ${uniHost}/30 dev uph
          ip link set uph up
          ip -n uni link set lo up
          ip -n uni addr add ${uniPeer}/30 dev upn
          ip -n uni link set upn up
          ip netns exec uni sysctl -qw net.ipv6.conf.all.disable_ipv6=1
        '';
        preStop = "ip link del uph 2>/dev/null || true";
      };

      # The one way out besides the VPN: the gateway's TLS port, relayed from the link.
      systemd.services.tunnel-uni-proxy = {
        description = "Relay from the uni tunnel to the FortiVPN gateway";
        after = [ "network-online.target" "tunnel-uni.service" ];
        wants = [ "network-online.target" ];
        requires = [ "tunnel-uni.service" ];
        unitConfig.ConditionPathExists = "${uniState}/config";
        serviceConfig.Restart = "always";
        serviceConfig.RestartSec = 5;
        script = ''
          host=$(${pkgs.gnused}/bin/sed -n 's/^host *= *//p' ${uniState}/config)
          port=$(${pkgs.gnused}/bin/sed -n 's/^port *= *//p' ${uniState}/config)
          exec ${pkgs.socat}/bin/socat TCP-LISTEN:${toString uniProxy},bind=${uniHost},reuseaddr,fork "TCP:$host:''${port:-443}"
        '';
      };
      networking.firewall.interfaces.uph.allowedTCPPorts = [ uniProxy ];

      # openfortivpn inside the namespace: ppp0 and its routes live there, and it keeps reconnecting.
      systemd.services.tunnel-uni-vpn = {
        description = "University FortiVPN inside the uni tunnel";
        after = [ "network-online.target" "tunnel-uni.service" "tunnel-uni-proxy.service" ];
        wants = [ "network-online.target" ];
        requires = [ "tunnel-uni.service" "tunnel-uni-proxy.service" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig.ConditionPathExists = "${uniState}/config";
        path = [ pkgs.iproute2 pkgs.ppp ];
        serviceConfig = {
          ExecStartPre = "${root}/bin/tunnel-root uni gateway";
          Restart = "always";
          RestartSec = 15;
        };
        # The gateway by name, so its certificate is checked against it, at the relay's port.
        script = ''
          host=$(${pkgs.gnused}/bin/sed -n 's/^host *= *//p' ${uniState}/config)
          exec ip netns exec uni ${hideResolvers} ${pkgs.openfortivpn}/bin/openfortivpn "$host:${toString uniProxy}" \
            -c ${uniState}/config --persistent=30 --set-routes=1 --half-internet-routes=1 \
            --set-dns=1 --use-resolvconf=0 --pppd-use-peerdns=0
        '';
      };

      networking.networkmanager.unmanaged = [ "interface-name:uph" ];
      # Nothing from the namespace is forwarded past the host. The ct mark is the one the
      # Mullvad app lets through its firewall, for the relay.
      networking.nftables.tables.uni = {
        family = "inet";
        content = ''
          chain tag {
            type filter hook prerouting priority mangle; policy accept;
            iifname "uph" ct mark set 0x00000f41
          }
          chain contain {
            type filter hook forward priority filter; policy accept;
            iifname "uph" drop
            oifname "uph" drop
          }
        '';
      };

      # Each drive: rclone serves the remote inside the tunnel, a second rclone mounts it here.
      systemd.user.services = lib.mkMerge (lib.mapAttrsToList (name: drive: let
        url = "http://${uniPeer}:${toString drive.port}";
        where = if drive.path != null then drive.path else "%h/${name}";
        configured = !(lib.hasPrefix ":" drive.remote);
        has = "${pkgs.bash}/bin/sh -c '${pkgs.rclone}/bin/rclone listremotes | grep -qx \"${lib.head (lib.splitString ":" drive.remote)}:\"'";
        # The SMB login from the credentials file, the password obscured as rclone takes it.
        serve = pkgs.writeShellScript "uni-serve-${name}" ''
          ${lib.optionalString (cfg.uni.credentials != null) ''
            if [ -r ${cfg.uni.credentials} ]; then
              RCLONE_SMB_USER=$(${pkgs.gnused}/bin/sed -n 's/^username=//p' ${cfg.uni.credentials})
              RCLONE_SMB_DOMAIN=$(${pkgs.gnused}/bin/sed -n 's/^domain=//p' ${cfg.uni.credentials})
              RCLONE_SMB_PASS=$(${pkgs.gnused}/bin/sed -n 's/^password=//p' ${cfg.uni.credentials} | ${pkgs.rclone}/bin/rclone obscure -)
              export RCLONE_SMB_USER RCLONE_SMB_DOMAIN RCLONE_SMB_PASS
            fi
          ''}
          # @user@ in the remote is the username from the credentials file.
          remote='${drive.remote}'
          remote=''${remote//@user@/''${RCLONE_SMB_USER:-}}
          exec /run/current-system/sw/bin/tunnel uni -- ${pkgs.rclone}/bin/rclone serve webdav "$remote" \
            --addr ${uniPeer}:${toString drive.port} --vfs-cache-mode writes
        '';
      in {
        "uni-serve-${name}" = {
          description = "Serve ${name} from inside the uni tunnel";
          wantedBy = [ "default.target" ];
          path = [ "/run/wrappers" "/run/current-system/sw" ];
          serviceConfig = {
            ExecCondition = lib.mkIf configured has;
            ExecStart = serve;
            Restart = "always";
            RestartSec = 20;
          };
        };
        "uni-mount-${name}" = {
          description = "Mount ${name} at ${where}, through the uni tunnel";
          wantedBy = [ "default.target" ];
          wants = [ "uni-serve-${name}.service" ];
          after = [ "uni-serve-${name}.service" ];
          path = [ "/run/wrappers" ];
          serviceConfig = {
            Type = "notify";
            ExecCondition = lib.mkIf configured has;
            ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${where}";
            ExecStart = "${pkgs.rclone}/bin/rclone mount :webdav,url=${url}: ${where} --vfs-cache-mode full --dir-cache-time 30s --volname ${name}";
            ExecStop = "/run/wrappers/bin/fusermount3 -uz ${where}";
            Restart = "on-failure";
            RestartSec = 20;
          };
        };
      }) cfg.uni.drives);
    })

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
