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
        adwaita-icon-theme
        fzy
        gnome-keyring
        grim
        hyprlock
        hyprpaper
        hyprpicker
        imv
        jq
        libnotify
        material-design-icons
        material-icons
        nordzy-cursor-theme
        pamixer
        playerctl
        quickshell
        satty
        slurp
        sqlite
        surfraw
        tesseract
        wayvnc
        wev
        wf-recorder
        wl-clipboard
        yaru-theme
      ];
      description = "Non-essential desktop/session utilities installed only when the desktop feature is enabled.";
    };
  };

  config = lib.mkIf (cfg.enable && config.bresilla.features.desktop.enable) {
    environment.systemPackages = cfg.packages;
    fonts.packages = with pkgs; [
      nerd-fonts.iosevka-term
      nerd-fonts.gohufont
      nerd-fonts.symbols-only
      material-design-icons
      material-icons
      noto-fonts-color-emoji
    ];
  };
}
