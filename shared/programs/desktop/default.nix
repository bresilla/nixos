{ config, lib, pkgs, bresilla, ... }:

let
  cfg = config.bresilla.programs.desktop;
  # The cursor Hyprland is told to use; nixpkgs does not package it.
  breezex-cursor = pkgs.stdenvNoCC.mkDerivation {
    pname = "breezex-cursor";
    version = "2.0.1";
    src = pkgs.fetchurl {
      url = "https://github.com/ful1e5/BreezeX_Cursor/releases/download/v2.0.1/BreezeX-Black.tar.xz";
      hash = "sha256-dzt1UjdIFzQJ7mIoQbD3Sx6AYXpcWz3LtTp6w9BswjM=";
    };
    installPhase = ''
      mkdir -p $out/share/icons/BreezeX-Black
      cp -r . $out/share/icons/BreezeX-Black
    '';
  };
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
        (bresilla.freerdp or freerdp)
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
        moonlight-qt
        mpv
        nordzy-cursor-theme
        breezex-cursor
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
        tigervnc
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
