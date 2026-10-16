{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.bresilla.features.desktop;
in
{
  options.bresilla.features.desktop = {
    enable = lib.mkEnableOption "desktop session";
    environment = lib.mkOption {
      type = lib.types.enum [
        "none"
        "hyprland"
        "river"
      ];
      default = "hyprland";
      description = "Wayland compositor to use for this host.";
    };
    flatpak.enable = lib.mkEnableOption "Flatpak";
    audio = {
      enable = lib.mkEnableOption "PipeWire audio";
      jack.enable = lib.mkEnableOption "PipeWire JACK compatibility";
    };
    apps = {
      browsers.enable = lib.mkEnableOption "browser applications";
      development.enable = lib.mkEnableOption "development applications";
      media.enable = lib.mkEnableOption "media applications";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.audio.enable {
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = pkgs.stdenv.hostPlatform.isx86_64;
        pulse.enable = true;
        jack.enable = cfg.audio.jack.enable;
      };
      security.rtkit.enable = true;
    })

    (lib.mkIf cfg.flatpak.enable {
      services.flatpak.enable = true;
      xdg.portal.enable = true;
      xdg.portal.config.common.default = "*";
    })

    (lib.mkIf (cfg.enable && cfg.environment == "hyprland") {
      # programs.hyprland adds xdg-desktop-portal-hyprland, which only covers
      # screenshots, screen sharing and global shortcuts. GTK supplies the
      # file picker, settings and the rest; GNOME Keyring stores secrets.
      xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      xdg.portal.config.hyprland = {
        default = [
          "hyprland"
          "gtk"
        ];
        "org.freedesktop.impl.portal.Secret" = [ "gnome-keyring" ];
      };
    })

    (lib.mkIf (cfg.enable && cfg.environment == "hyprland") {
      programs.hyprland.enable = true;
      environment.sessionVariables = {
        XDG_CURRENT_DESKTOP = "Hyprland";
        XDG_SESSION_DESKTOP = "Hyprland";
        QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
      };
    })

    (lib.mkIf cfg.enable {
      # Flatpak enables fontDir; embedding its path rebuilds Xwayland.
      # Fontconfig and Flatpak can use the installed fonts without that override.
      programs.xwayland.defaultFontPath = lib.mkDefault "";
      security.polkit.enable = true;
      programs.dconf.enable = true;
      # Dark by default; Lule overrides these per scheme in the user database.
      programs.dconf.profiles.user.databases = [
        {
          settings."org/gnome/desktop/interface" = {
            color-scheme = "prefer-dark";
            gtk-theme = "Yaru-dark";
          };
        }
      ];
      # Secret storage stays in GNOME Keyring; Morf provides its dialogs.
      services.gnome.gnome-keyring.enable = true;
      xdg.mime.enable = true;

      environment.sessionVariables = {
        GTK_USE_PORTAL = "1";
        XDG_SESSION_TYPE = "wayland";
        QT_AUTO_SCREEN_SCALE_FACTOR = "1";
        QT_QPA_PLATFORM = "wayland";
        HEXE_UNRESTRICTED_CONFIG = "1";
      };
    })
  ];
}
