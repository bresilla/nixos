{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.canup;
  ip = "${pkgs.iproute2}/bin/ip";
in
{
  options.bresilla.services.canup = {
    enable = lib.mkEnableOption "virtual CAN interfaces (canup@<name>)";
    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "vcan0" ];
      description = "Virtual CAN interfaces brought up at boot; others start with systemctl start canup@<name>.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [ "vcan" ];
    environment.systemPackages = [ pkgs.can-utils ];
    systemd.services."canup@" = {
      description = "Bring VCAN up (%I)";
      after = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [
          "-${ip} link add dev %I type vcan"
          "${ip} link set up %I"
        ];
        ExecStop = "${ip} link delete %I";
      };
    };
    systemd.targets.multi-user.wants = map (name: "canup@${name}.service") cfg.interfaces;
  };
}
