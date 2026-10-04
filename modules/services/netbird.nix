{ config, lib, ... }:

let
  cfg = config.bresilla.services.netbird;
in
{
  options.bresilla.services.netbird = {
    enable = lib.mkEnableOption "NetBird VPN client" // {
      default = true;
    };

    routingFeatures = lib.mkOption {
      type = lib.types.enum [
        "none"
        "client"
        "server"
        "both"
      ];
      default = "none";
      description = "NetBird routing feature mode.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.netbird = {
      enable = true;
      useRoutingFeatures = cfg.routingFeatures;
      clients.default = {
        interface = "netbird0";
        config.DisableDNS = true;
      };
    };

    networking.firewall.trustedInterfaces = [ "netbird0" ];
  };
}
