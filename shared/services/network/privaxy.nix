{ config, lib, pkgs, bresilla, ... }:

let
  cfg = config.bresilla.services.privaxy;
  # Not in nixpkgs; built by packages/ and pinned, so machines only download it.
  inherit (bresilla) privaxy;
in
{
  options.bresilla.services.privaxy.enable =
    lib.mkEnableOption "the Privaxy tracker and advertisement blocker";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ privaxy ];
    systemd.user.services.privaxy = {
      description = "Privaxy tracker and advertisement blocker";
      documentation = [ "https://github.com/barre/privaxy" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = "${privaxy}/bin/privaxy";
        ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR1 $MAINPID";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
