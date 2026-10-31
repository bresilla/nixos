{ config, lib, pkgs, bresilla, ... }:

let
  cfg = config.bresilla.programs.desktop;
  # The cursor Hyprland is told to use; built by packages/ and pinned.
  breezex-cursor = bresilla.breezex-cursor or (pkgs.callPackage ../../packages/breezex-cursor.nix { });
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
      ]
      # Only machines serving the remote session; the bresilla cache pins it for x86_64 only.
      ++ lib.optional (config.bresilla.system.remote.rdp.enable && (bresilla.hypr-rdp or null) != null) bresilla.hypr-rdp;
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
