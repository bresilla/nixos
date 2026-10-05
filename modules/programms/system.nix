{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.system;
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
        btop
        ddcutil
        ethtool
        evtest
        lsb-release
        lm_sensors
        ncdu
        nvme-cli
        pavucontrol
        pciutils
        usbutils
        v4l-utils
      ];
      description = "System-level tools installed on every host.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = cfg.packages;
    hardware.i2c.enable = true;
    users.users.${config.bresilla.user.name}.extraGroups = [ "i2c" ];
  };
}
