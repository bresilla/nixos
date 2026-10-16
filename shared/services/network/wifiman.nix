{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.wifiman;
  # Only the daemon from Ubiquiti's .deb; it finds wg, wg-quick and wireguard-go beside itself.
  daemon = pkgs.stdenv.mkDerivation rec {
    pname = "wifiman-desktopd";
    version = "1.3.0";
    src = pkgs.fetchurl {
      url = "https://desktop.wifiman.com/wifiman-desktop-${version}-amd64.deb";
      hash = "sha256-K7dbc8CS5DWSu9QIQWKPIiAAvqlaKDiar+hK2vJ5zXg=";
    };
    nativeBuildInputs = [ pkgs.dpkg pkgs.autoPatchelfHook ];
    unpackPhase = "dpkg-deb -x $src .";
    installPhase = ''
      mkdir -p $out/lib
      cp -r usr/lib/wifiman-desktop $out/lib/
      chmod +x $out/lib/wifiman-desktop/wg-quick
    '';
    meta.platforms = [ "x86_64-linux" ];
  };
in
{
  options.bresilla.services.wifiman.enable =
    lib.mkEnableOption "the WiFiman Teleport daemon, without its GUI";

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isx86_64) {
    systemd.services.wifiman-desktop = {
      description = "WiFiman Teleport daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      # wg-quick and the daemon call these by name.
      path = with pkgs; [
        bash
        coreutils
        gawk
        gnugrep
        gnused
        iproute2
        iw
        nettools
        networkmanager
        openresolv
        procps
        wireguard-tools
      ];
      # It saves settings beside its own binary, and its .env holds the timings;
      # without that file the speed test pings in a tight loop.
      preStart = ''
        for f in ${daemon}/lib/wifiman-desktop/* ${daemon}/lib/wifiman-desktop/.env*; do
          install -m 0755 "$f" "/var/lib/wifiman-desktop/$(basename "$f")"
        done
        # The daemon drops wg-quick's errors; keep them in wg-quick.log.
        mv /var/lib/wifiman-desktop/wg-quick /var/lib/wifiman-desktop/wg-quick.real
        printf '#!%s\nexec %s "$@" 2>>%s\n' ${pkgs.bash}/bin/bash \
          /var/lib/wifiman-desktop/wg-quick.real /var/lib/wifiman-desktop/wg-quick.log \
          > /var/lib/wifiman-desktop/wg-quick
        chmod 0755 /var/lib/wifiman-desktop/wg-quick
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
