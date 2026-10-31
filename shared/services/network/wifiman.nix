{ config, lib, pkgs, bresilla, ... }:

let
  cfg = config.bresilla.services.wifiman;
  # Daemon and CLI are built by packages/ and pinned, so machines only download them.
  daemon = bresilla.wifiman-desktopd;
  cli = bresilla.wifiman;
  # Stands in for the bundled wg-quick: keeps its errors, which the daemon drops, and
  # gives each tunnel the first free teleportN altname; the daemon still tracks wgwfm*.
  wgQuick = pkgs.writeShellScript "wg-quick" ''
    state=/var/lib/wifiman-desktop
    ${pkgs.bash}/bin/bash "$state/wg-quick.real" "$@" 2>>"$state/wg-quick.log" || exit
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
