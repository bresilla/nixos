{ lib, pkgs, ... }:

let
  pointerConfig = ''
    hl.config({ cursor = { invisible = true } })
  '';
  # A reviewed Lua fix for existing user themes; the Morf binary continues
  # to follow the current cache pin. No application or kernel rebuild.
  phoneGestures = pkgs.linkFarm "morf-phone-gestures" [
    {
      name = "phone_gestures.lua";
      path = pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/paneworks/morf/dab729a130c962cc03570a249ab63e452b866278/examples/shells/caelestia/shell/phone_gestures.lua";
        hash = "sha256-VexEThMkcKwM3ggXSSwFS7o9K2+078NMs+OI25qisew=";
      };
    }
    {
      name = "plugin/phone-gestures.lua";
      path = ../services/morf-phone-gestures-plugin.lua;
    }
  ];
in {
  imports = [ ./graphical.nix ../services/phone-screen.nix ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  # Phone-specific choices stay here; graphical software is shared with laptops.
  services.smartd.enable = false;
  bresilla.services.hyprland.extraConfig = pointerConfig;
  bresilla.services.morf.greeter.extraConfig = pointerConfig;

  # Keep phone preferences writable and stable when the theme path changes.
  # Seed the visible bar once; Caelestia can save other preferences normally.
  systemd.user.services.morf = {
    environment.CAELESTIA_SETTINGS = "%h/.local/state/caelestia/phone.json";
    environment.MORF_RUNTIME_PATH = "${phoneGestures}";
    preStart = ''
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$CAELESTIA_SETTINGS")"
      if [ ! -e "$CAELESTIA_SETTINGS" ]; then
        ${pkgs.coreutils}/bin/install -m 600 ${pkgs.writeText "caelestia-phone.json" (builtins.toJSON {
          edgebar.enabled = "on";
        })} "$CAELESTIA_SETTINGS"
      fi
    '';
  };
}
