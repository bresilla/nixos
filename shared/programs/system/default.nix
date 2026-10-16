{
  config,
  lib,
  pkgs,
  ...
}:
let
  system = config.bresilla.programs.system;
in
{
  options.bresilla.programs.system = {
    enable = lib.mkEnableOption "system inspection and maintenance programs" // {
      default = true;
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        btop
        ethtool
        evtest
        lsb-release
        lm_sensors
        ncdu
        nvme-cli
        pciutils
        usbutils
        v4l-utils
      ];
      description = "System-level tools installed on every host.";
    };
  };

  config = lib.mkIf system.enable { environment.systemPackages = system.packages; };
}
