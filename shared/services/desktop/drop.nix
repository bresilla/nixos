{ config, lib, pkgs, termworks, ... }:

let
  cfg = config.bresilla.services.drop;
  drop = termworks.drop.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  options.bresilla.services.drop.enable =
    lib.mkEnableOption "the drop peer-to-peer file transfer daemon";

  config = lib.mkIf cfg.enable {
    systemd.user.services.drop = {
      description = "drop peer-to-peer file transfer";
      documentation = [ "https://github.com/bresilla/drop" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${drop}/bin/drop daemon";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };
  };
}
