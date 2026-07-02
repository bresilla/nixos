{ config, lib, ... }:

let
  cfg = config.bresilla.services.tailscale;
in
{
  options.bresilla.services.tailscale = {
    enable = lib.mkEnableOption "Tailscale mesh VPN" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      interfaceName = "tailscale0";
    };
    networking.firewall.trustedInterfaces = [ "tailscale0" ];
  };
}
