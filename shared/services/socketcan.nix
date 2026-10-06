{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.bresilla.services.socketcan;

  mkVcanNetdev =
    name: _:
    lib.nameValuePair "10-${name}" {
      netdevConfig = {
        Kind = "vcan";
        Name = name;
      };
    };

  mkVcanNetwork =
    name: _:
    lib.nameValuePair "10-${name}" {
      matchConfig.Name = name;
      linkConfig.ActivationPolicy = "always-up";
    };
in
{
  options.bresilla.services.socketcan = {
    enable = lib.mkEnableOption "SocketCAN support" // {
      default = true;
    };

    virtualInterfaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.bitrate = lib.mkOption {
            type = lib.types.ints.positive;
            default = 250000;
            description = "Nominal CAN bitrate kept for matching real CAN defaults; virtual CAN does not use it.";
          };
        }
      );
      default = {
        vcan0 = { };
      };
      description = "Virtual CAN interfaces to create for testing.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [ "vcan" ];
    environment.systemPackages = [ pkgs.can-utils ];

    systemd.network.enable = true;
    systemd.network.netdevs = lib.mapAttrs' mkVcanNetdev cfg.virtualInterfaces;
    systemd.network.networks = lib.mapAttrs' mkVcanNetwork cfg.virtualInterfaces;
  };
}
