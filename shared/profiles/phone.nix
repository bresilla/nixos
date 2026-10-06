{ lib, pkgs, ... }:

let
  pointerConfig = ''
    hl.config({ cursor = { invisible = true } })
  '';
  # Compatibility modules for existing user checkouts, without editing dotfiles.
  themeFix = path: hash: pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/e9785ba4bfaea583ac41ff688001e48c94f4d011/examples/shells/caelestia/${path}";
    inherit hash;
  };
  phoneGestures = pkgs.linkFarm "morf-phone-gestures" [
    {
      name = "phone_gestures.lua";
      path = themeFix "shell/phone_gestures.lua" "sha256-Q9Jg+wg+x0rmiD5df5Xyzw/Nj/njDWW01VSkuDN9Znw=";
    }
    {
      name = "phone_repair/tabbed.lua";
      path = themeFix "themes/layouts/tabbed.lua" "sha256-we6NjkWc/3WL/yAq73a/t5skZkx4VepEOMQeZP4OfKI=";
    }
    {
      name = "phone_repair/dashboard.lua";
      path = themeFix "themes/layouts/views/dashboard.lua" "sha256-fEtC6cWf0BckmWg/Ml/o+KbQFF7GUuJzfPWjElgCalE=";
    }
    {
      name = "phone_repair/side_panel.lua";
      path = themeFix "themes/layouts/views/side_panel.lua" "sha256-3EZwSSltPbAt8MSrNEGlNkbxK/sBYxOrXVQ+ThIevqY=";
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
