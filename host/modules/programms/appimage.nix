{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.appimage;
  appType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Command name for the AppImage wrapper.";
      };
      url = lib.mkOption {
        type = lib.types.str;
        description = "URL to download the AppImage from.";
      };
      sha256 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional sha256 checksum for the downloaded AppImage.";
      };
    };
  };
in
{
  options.bresilla.programs.appimage = {
    enable = lib.mkEnableOption "managed AppImage downloads and wrappers" // {
      default = true;
    };
    downloads = lib.mkOption {
      type = lib.types.listOf appType;
      default = [ ];
      description = "AppImages to download into /var/lib/appimages when enabled.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (app: app.sha256 != null) cfg.downloads;
        message = "bresilla.programs.appimage.downloads entries must set sha256.";
      }
    ];

    environment.systemPackages =
      [ pkgs.appimage-run ]
      ++ map (app:
        pkgs.writeShellScriptBin app.name ''
          exec ${pkgs.appimage-run}/bin/appimage-run /var/lib/appimages/${app.name}.AppImage "$@"
        ''
      ) cfg.downloads;

    systemd.tmpfiles.rules = [
      "d /var/lib/appimages 0755 root root -"
    ];

    systemd.services.appimage-downloads = lib.mkIf (cfg.downloads != [ ]) {
      description = "Download managed AppImages";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
        coreutils
        curl
        gnugrep
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        install -d -m 0755 /var/lib/appimages

        ${lib.concatMapStringsSep "\n" (app: ''
          target=/var/lib/appimages/${lib.escapeShellArg "${app.name}.AppImage"}
          tmp="$target.tmp"

          if [ ! -x "$target" ]; then
            curl --fail --location --show-error --output "$tmp" ${lib.escapeShellArg app.url}
            ${lib.optionalString (app.sha256 != null) ''
              printf '%s  %s\n' ${lib.escapeShellArg app.sha256} "$tmp" | sha256sum --check
            ''}
            install -m 0755 -o root -g root "$tmp" "$target"
            rm -f "$tmp"
          fi
        '') cfg.downloads}
      '';
    };
  };
}
