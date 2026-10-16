{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.canup;
  ip = "${pkgs.iproute2}/bin/ip";
  # CAN FD on vcan is plain vcan with the FD frame MTU (72) instead of 16.
  unit = description: mtu: {
    inherit description;
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "-${ip} link add dev %I type vcan"
        "${ip} link set dev %I mtu ${toString mtu}"
        "${ip} link set dev %I up"
      ];
      ExecStop = "${ip} link delete %I";
    };
  };
in
{
  options.bresilla.services.canup = {
    enable = lib.mkEnableOption "virtual CAN interfaces (canup@<name>, canupfd@<name> for CAN FD)";
    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "vcan0" ];
      description = "Classic virtual CAN interfaces brought up at boot; others start with systemctl start canup@<name>.";
    };
    fdInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "vcanfd0" ];
      description = "Virtual CAN FD interfaces brought up at boot; others start with systemctl start canupfd@<name>.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [ "vcan" ];
    environment.systemPackages = [ pkgs.can-utils ];
    systemd.services."canup@" = unit "Bring VCAN up (%I)" 16;
    systemd.services."canupfd@" = unit "Bring VCAN FD up (%I)" 72;
    systemd.targets.multi-user.wants =
      map (name: "canup@${name}.service") cfg.interfaces
      ++ map (name: "canupfd@${name}.service") cfg.fdInterfaces;
  };
}
