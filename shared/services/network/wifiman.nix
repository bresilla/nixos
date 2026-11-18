{ config, lib, pkgs, bresilla, ... }:

let
  cfg = config.bresilla.services.wifiman;
  # Daemon and CLI are built by packages/ and pinned, so machines only download them.
  daemon = bresilla.wifiman-desktopd;
  cli = bresilla.wifiman;
  teleport = config.bresilla.services.tunnels.teleport.enable;
  # For `tunnel teleport`: the same connection without DNS, its whole-machine rules taken
  # out right after up (its socket mark stays, which the console's replies need); only
  # the namespace's table routes to it, and its resolver is the namespace's.
  namespaced = pkgs.writeShellScript "wg-quick-teleport" ''
    state=/var/lib/wifiman-desktop run=/run/tunnels/teleport
    ip=${pkgs.iproute2}/bin/ip
    mkdir -p "$run"
    conf=$run/$(basename "$2")
    snap() { for v in 4 6; do $ip -$v rule > "$run/rules$v"; done; }
    if [ "$1" = up ]; then
      sed -n 's/^[[:space:]]*DNS[[:space:]]*=//Ip' "$2" | tr ', ' '\n\n' | sed -n 's/^\(.\+\)$/nameserver \1/p' > "$run/resolv.conf.new"
      mv "$run/resolv.conf.new" "$run/resolv.conf"
      (umask 077; ${pkgs.gawk}/bin/awk 'tolower($0) !~ /^[[:space:]]*dns[[:space:]]*=/' "$2" > "$conf")
      snap
      ${pkgs.bash}/bin/bash "$state/wg-quick.real" up "$conf" 2>>"$state/wg-quick.log" || exit
      for v in 4 6; do
        $ip -$v rule | grep -vxFf "$run/rules$v" | cut -d: -f1 | while read -r p; do $ip -$v rule del pref "$p"; done
      done
      iface=$(basename "$2" .conf)
      $ip route replace default dev "$iface" table ${toString config.bresilla.services.tunnels.teleport.table}
      ${pkgs.procps}/bin/sysctl -qw "net.ipv4.conf.$iface.forwarding=1"
    else
      # Its teardown deletes every suppress rule, NetBird's too; what it took goes back.
      snap
      ${pkgs.bash}/bin/bash "$state/wg-quick.real" "$1" "$conf" 2>>"$state/wg-quick.log"; rc=$?
      for v in 4 6; do
        grep -vxFf <($ip -$v rule) "$run/rules$v" | while IFS=: read -r p rest; do $ip -$v rule add pref "$p" $rest; done
      done
      [ "$1" = down ] && { rm -f "$conf" /run/tunnels/teleport.ns; echo "# Teleport is down" > "$run/resolv.conf"; }
      exit $rc
    fi
  '';
  # Stands in for the bundled wg-quick: keeps its errors, which the daemon drops, and
  # gives each tunnel the first free teleportN altname; the daemon still tracks wgwfm*.
  wgQuick = pkgs.writeShellScript "wg-quick" ''
    state=/var/lib/wifiman-desktop
    ${lib.optionalString teleport ''
      if { [ "$1" = up ] && [ -e /run/tunnels/teleport.ns ]; } || { [ "$1" != up ] && [ -e "/run/tunnels/teleport/$(basename "$2")" ]; }; then
        ${namespaced} "$@" || exit
      else
    ''}
    ${pkgs.bash}/bin/bash "$state/wg-quick.real" "$@" 2>>"$state/wg-quick.log" || exit
    ${lib.optionalString teleport "fi"}
    if [ "$1" = up ]; then
      iface=$(basename "$2" .conf)
      n=0
      while ${pkgs.iproute2}/bin/ip link show "teleport$n" >/dev/null 2>&1; do n=$((n + 1)); done
      ${pkgs.iproute2}/bin/ip link property add dev "$iface" altname "teleport$n" 2>>"$state/wg-quick.log" || true
    fi
  '';
in
{
  options.bresilla.services.wifiman.enable =
    lib.mkEnableOption "the WiFiman Teleport daemon, without its GUI";

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isx86_64) {
    environment.systemPackages = [ cli ];
    systemd.services.wifiman-desktop = {
      description = "WiFiman Teleport daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      # wg-quick and the daemon call these by name; resolvconf is systemd-resolved's.
      path = [ config.systemd.package ] ++ (with pkgs; [
        bash
        coreutils
        gawk
        gnugrep
        gnused
        iproute2
        iw
        nettools
        networkmanager
        nftables
        procps
        wireguard-tools
      ]);
      # It saves settings beside its own binary, and its .env holds the timings;
      # without that file the speed test pings in a tight loop.
      preStart = ''
        for f in ${daemon}/lib/wifiman-desktop/* ${daemon}/lib/wifiman-desktop/.env*; do
          install -m 0755 "$f" "/var/lib/wifiman-desktop/$(basename "$f")"
        done
        mv /var/lib/wifiman-desktop/wg-quick /var/lib/wifiman-desktop/wg-quick.real
        install -m 0755 ${wgQuick} /var/lib/wifiman-desktop/wg-quick
        for log in /var/lib/wifiman-desktop/wifiman-desktop.log /var/lib/wifiman-desktop/wg-quick.log; do
          if [ -f "$log" ] && [ "$(stat -c %s "$log")" -gt 52428800 ]; then : > "$log"; fi
        done
      '';
      serviceConfig = {
        StateDirectory = "wifiman-desktop";
        ExecStart = "/var/lib/wifiman-desktop/wifiman-desktopd";
        Restart = "always";
        RestartSec = 30;
      };
    };
  };
}
