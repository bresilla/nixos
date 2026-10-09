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
        adwaita-icon-theme
        alacritty
        android-tools
        brightnessctl
        ddcutil
        ffmpeg
        fzy
        grim
        hyprlock
        hyprpaper
        hyprpicker
        imv
        jq
        kitty
        libnotify
        material-design-icons
        material-icons
        mpv
        nordzy-cursor-theme
        pamixer
        pavucontrol
        playerctl
        quickshell
        satty
        slurp
        spotifyd
        sqlite
        surfraw
        tesseract
        wayvnc
        wev
        wf-recorder
        wl-clipboard
        yaru-theme
        zathura
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
