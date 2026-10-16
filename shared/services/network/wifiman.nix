{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.wifiman;
  # Ubiquiti ships only a .deb; its daemon finds wg, wg-quick and wireguard-go beside itself.
  wifiman = pkgs.stdenv.mkDerivation rec {
    pname = "wifiman-desktop";
    version = "1.3.0";
    src = pkgs.fetchurl {
      url = "https://desktop.wifiman.com/wifiman-desktop-${version}-amd64.deb";
      hash = "sha256-K7dbc8CS5DWSu9QIQWKPIiAAvqlaKDiar+hK2vJ5zXg=";
    };
    nativeBuildInputs = with pkgs; [ dpkg autoPatchelfHook wrapGAppsHook3 ];
    buildInputs = with pkgs; [
      gtk3
      webkitgtk_4_1
      libsoup_3
      glib
      cairo
      gdk-pixbuf
      dbus
      stdenv.cc.cc.lib
    ];
    unpackPhase = "dpkg-deb -x $src .";
    installPhase = ''
      mkdir -p $out
      cp -r usr/bin usr/lib usr/share $out/
      chmod +x $out/lib/wifiman-desktop/wg-quick
      # The browser returns the login as a wifiman-desktop-dl:// link; %u passes it on.
      substituteInPlace $out/share/applications/wifiman-desktop.desktop \
        --replace-fail "Exec=wifiman-desktop" "Exec=wifiman-desktop %u"
    '';
    # The tray icon library is loaded at runtime, not linked.
    preFixup = ''
      gappsWrapperArgs+=(--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.libayatana-appindicator ]})
    '';
    meta.platforms = [ "x86_64-linux" ];
  };
in
{
  options.bresilla.services.wifiman.enable =
    lib.mkEnableOption "Ubiquiti WiFiman Desktop and its Teleport VPN daemon";

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isx86_64) {
    environment.systemPackages = [ wifiman ];
    systemd.services.wifiman-desktop = {
      description = "wifiman-desktop";
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
      # The daemon saves its settings beside its own binary, so it runs from a writable copy.
      # Its .env holds the timings; without it the speed test pings in a tight loop.
      preStart = ''
        for f in ${wifiman}/lib/wifiman-desktop/* ${wifiman}/lib/wifiman-desktop/.env*; do
          install -m 0755 "$f" "/var/lib/wifiman-desktop/$(basename "$f")"
        done
        log=/var/lib/wifiman-desktop/wifiman-desktop.log
        if [ -f "$log" ] && [ "$(stat -c %s "$log")" -gt 52428800 ]; then : > "$log"; fi
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
