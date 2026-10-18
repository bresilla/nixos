{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.spotifyd;
in
{
  options.bresilla.services.spotifyd.enable =
    lib.mkEnableOption "the spotifyd player, configured by ~/.config/spotifyd/spotifyd.conf";

  config = lib.mkIf cfg.enable {
    systemd.user.services.spotifyd = {
      description = "A spotify playing daemon";
      documentation = [ "https://github.com/Spotifyd/spotifyd" ];
      wants = [ "sound.target" "network-online.target" ];
      after = [ "sound.target" "network-online.target" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.spotifyd}/bin/spotifyd --no-daemon --device-name %H --config-path %h/.config/spotifyd/spotifyd.conf";
        Restart = "always";
        RestartSec = 12;
      };
    };
  };
}
