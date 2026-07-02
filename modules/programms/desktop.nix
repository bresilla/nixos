{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.desktop;
in
{
  options.bresilla.programs.desktop = {
    enable = lib.mkEnableOption "desktop session utilities" // {
      default = true;
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        android-tools
        grim
        pamixer
        playerctl
        satty
        slurp
        wayvnc
        wev
        wf-recorder
        wl-clipboard
      ];
      description = "Non-essential desktop/session utilities installed only when the desktop feature is enabled.";
    };
  };

  config = lib.mkIf (cfg.enable && config.bresilla.features.desktop.enable) {
    environment.systemPackages = cfg.packages;
  };
}
