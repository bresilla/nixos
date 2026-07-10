{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.system;
  nox = pkgs.callPackage ../../rewrite/package.nix { };
in
{
  options.bresilla.programs.system = {
    enable = lib.mkEnableOption "system inspection and maintenance programs" // {
      default = true;
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = (with pkgs; [
        brightnessctl
        lsb-release
        lm_sensors
        pavucontrol
      ]) ++ [ nox ];
      description = "System-level tools installed on every host.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = cfg.packages;
  };
}
