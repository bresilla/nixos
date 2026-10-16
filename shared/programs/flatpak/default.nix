{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.flatpak;
in
{
  options.bresilla.programs.flatpak = {
    apps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "com.github.tchx84.Flatseal"
        "org.mozilla.firefox"
        "app.zen_browser.zen"
        "org.chromium.Chromium"
        "net.lockbook.Lockbook"
        "com.anydesk.Anydesk"
        "com.rustdesk.RustDesk"
        "com.freerdp.FreeRDP"
        "com.moonlight_stream.Moonlight"
        "org.zotero.Zotero"
      ]
      # Flathub ships these for x86_64 only.
      ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
        "com.microsoft.EdgeDev"
        "com.spotify.Client"
        "com.valvesoftware.SteamLink"
      ];
      description = "Flatpak application IDs to install. Unlisted Flatpaks are left alone.";
    };
  };

  config = lib.mkIf (config.bresilla.features.desktop.flatpak.enable && cfg.apps != [ ]) {
    systemd.services.flatpak-default-apps = {
      description = "Install default Flatpak applications";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "flatpak-system-helper.service"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [
        config.services.flatpak.package
        pkgs.coreutils
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # network-online can come before Wi-Fi does; retry until Flathub answers.
        Restart = "on-failure";
        RestartSec = "30s";
      };
      unitConfig = {
        StartLimitIntervalSec = 600;
        StartLimitBurst = 10;
      };

      script = ''
        flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

        ${lib.concatMapStringsSep "\n" (app: ''
          if flatpak info --system ${lib.escapeShellArg app} >/dev/null 2>&1; then
            flatpak update --system --noninteractive ${lib.escapeShellArg app}
          else
            flatpak install --system --noninteractive flathub ${lib.escapeShellArg app}
          fi
        '') cfg.apps}
      '';
    };
  };
}
