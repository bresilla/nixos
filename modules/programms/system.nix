{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.system;
  nx = pkgs.writeShellApplication {
    name = "nx";
    text = ''
      exec /etc/nixos/nx "$@"
    '';
  };
in
{
  options.bresilla.programs.system = {
    enable = lib.mkEnableOption "system inspection and maintenance programs" // {
      default = true;
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        brightnessctl
        lsb-release
        lm_sensors
        nx
        pavucontrol
      ];
      description = "System-level tools installed on every host.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = cfg.packages;
  };
}
