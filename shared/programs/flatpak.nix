{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.flatpak;
in
{
  options.bresilla.programs.flatpak = {
    apps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Flatpak application IDs to install. Unlisted Flatpaks are left alone.";
    };
    overrides = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = { "org.blender.Blender" = [ "--filesystem=/srv/assets" "--talk-name=org.freedesktop.Flatpak" ]; };
      description = "`flatpak override --system` arguments per application ID; each listed app's system overrides are exactly these.";
    };
  };

  config = lib.mkIf (config.bresilla.features.desktop.flatpak.enable && (cfg.apps != [ ] || cfg.overrides != { })) {
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
        pkgs.getent
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
        # A switch restarts this while DNS can be briefly down; wait up to a minute.
        for _ in $(seq 30); do
          getent hosts flathub.org >/dev/null && break
          sleep 2
        done

        flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

        ${lib.concatMapStringsSep "\n" (app: ''
          if flatpak info --system ${lib.escapeShellArg app} >/dev/null 2>&1; then
            flatpak update --system --noninteractive ${lib.escapeShellArg app}
          else
            flatpak install --system --noninteractive flathub ${lib.escapeShellArg app}
          fi
        '') cfg.apps}

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (app: args: ''
          flatpak override --system --reset ${lib.escapeShellArg app}
          flatpak override --system ${lib.escapeShellArgs args} ${lib.escapeShellArg app}
        '') cfg.overrides)}
      '';
    };
  };
}
