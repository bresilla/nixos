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
