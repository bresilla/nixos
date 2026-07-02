{ config, lib, ... }:

let
  cfg = config.bresilla.services.wireguard;
in
{
  options.bresilla.services.wireguard = {
    enable = lib.mkEnableOption "WireGuard support" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    networking.wireguard.enable = true;
  };
}
