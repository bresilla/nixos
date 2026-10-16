{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.mpris;
in
{
  options.bresilla.services.mpris.enable =
    lib.mkEnableOption "forwarding Bluetooth media controls to MPRIS players";

  config = lib.mkIf cfg.enable {
    systemd.user.services.mpris = {
      description = "Forward Bluetooth media controls via MPRIS2 to supporting media players";
      after = [ "bluetooth.target" ];
      wantedBy = [ "default.target" ];
      serviceConfig.ExecStart = "${pkgs.bluez}/bin/mpris-proxy";
    };
  };
}
