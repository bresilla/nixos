{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.greenclip;
  greenclip = pkgs.haskellPackages.greenclip;
in
{
  options.bresilla.services.greenclip.enable =
    lib.mkEnableOption "the greenclip clipboard manager";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ greenclip ];
    systemd.user.services.greenclip = {
      description = "Clipboard manager for ROFI";
      documentation = [ "https://github.com/erebe/greenclip" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${greenclip}/bin/greenclip daemon";
        ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR1 $MAINPID";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
