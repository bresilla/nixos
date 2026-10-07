{ lib, pkgs, ... }:

let
  pointerConfig = ''
    hl.config({ cursor = { invisible = true } })
  '';
  workspaceConfig = ''
    -- Hyprland owns the side-edge contact, including a held or reversed swipe.
    hl.config({ gestures = {
      workspace_swipe_touch = true,
      workspace_swipe_touch_invert = false,
      workspace_swipe_cancel_ratio = 0.5,
      workspace_swipe_min_speed_to_force = 0,
    } })
    hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "default", style = "slide" })
  '';
  # Compatibility modules for existing user checkouts, without editing dotfiles.
  themeFix = path: hash: pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/16260a2c75de4bc33a9e730b6bd44cd4c1db5238/examples/shells/caelestia/${path}";
    inherit hash;
  };
  phoneGestures = pkgs.linkFarm "morf-phone-gestures" [
    {
      name = "keyboard_gestures.lua";
      path = themeFix "shell/keyboard_gestures.lua" "sha256-xmehVzn0p5wZfg9lltcBg1y75jKV4qUSv1ZCAHaQtBc=";
    }
    {
      name = "phone_repair/keyboard.lua";
      path = themeFix "themes/layouts/views/keyboard.lua" "sha256-Gzo2xlVWUqrwHaFeFx+IxP7WT+D4n5oFmuXCMXMEa2Q=";
    }
    {
      name = "phone_gestures.lua";
      path = themeFix "shell/phone_gestures.lua" "sha256-gZogr8Xr/PXXOyrRpQHjnlNZ9NnTY1HCdjjZXIqoQWs=";
    }
    {
      name = "drawer_drag.lua";
      path = themeFix "shell/drawer_drag.lua" "sha256-zvduNpQmTbMDLSj251Qg50iYel4BuodGTYmbpLDSylI=";
    }
    {
      name = "pager_drag.lua";
      path = themeFix "shell/pager_drag.lua" "sha256-BtwfCfUphv2DFWVNh+gom0MzExPZM4ZV7n5nNFvLCZk=";
    }
    {
      name = "phone_repair/drawer.lua";
      path = themeFix "shell/drawer.lua" "sha256-Ew6GkzCL1JWZLp2jdtQn85V58UZJzZy6YFtVUNR5RPo=";
    }
    {
      name = "phone_repair/material_motion.lua";
      path = themeFix "themes/material/motion.lua" "sha256-MxZjZD0M+GBrG86Tw0C6SeQhQrIF/9IV9OkvQLm+1ZU=";
    }
    {
      name = "phone_repair/tsugumori_motion.lua";
      path = themeFix "themes/tsugumori/motion.lua" "sha256-0aypqDJ7T1QF7nL+6Do1BAw+YGj2F2yDt7UkGGILRqU=";
    }
    {
      name = "phone_repair/control.lua";
      path = pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/paneworks/morf/24bae346b359badda122b06a1dbecd7189ad80c0/library/lib/kit/control.lua";
        hash = "sha256-fYXcI7pFQM7u/hP4J+VMcC6gM/vnyg2QcElfYSJSWbY=";
      };
    }
    {
      name = "phone_repair/tabbed.lua";
      path = themeFix "themes/layouts/tabbed.lua" "sha256-lQLQ5u5ftm9Wxgs6+rNzNQiASMauVoUjPOgBghTMNtI=";
    }
    {
      name = "phone_repair/dashboard.lua";
      path = themeFix "themes/layouts/views/dashboard.lua" "sha256-/kKn6078yr8+yPgl1C9uaM6+0zhwohwkN9Npbd4GPpE=";
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
  # Leave memory for the compositor while building updates on the device.
  nix.settings.max-jobs = lib.mkDefault 1;
  nix.settings.cores = lib.mkDefault 2;
  # Phone-specific choices stay here; graphical software is shared with laptops.
  services.smartd.enable = false;
  bresilla.services.hyprland.extraConfig = pointerConfig + workspaceConfig;
  bresilla.services.morf.greeter.extraConfig = pointerConfig;
  bresilla.services.morf.runtimePaths = [ phoneGestures ];

  # Keep phone preferences writable and stable when the theme path changes.
  # Seed the visible bar once; Caelestia can save other preferences normally.
  systemd.user.services.morf = {
    environment.CAELESTIA_WORKSPACE_GESTURES = "compositor";
    environment.CAELESTIA_SETTINGS = "%h/.local/state/caelestia/phone.json";
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
