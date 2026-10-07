{ lib, pkgs, ... }:

let
  pointerConfig = ''
    hl.config({ cursor = { invisible = true } })
  '';
  workspaceConfig = ''
    -- Morf owns touchscreen edges and draws its workspace previews. Only
    -- a completed gesture sends a normal workspace-switch command.
    hl.config({ gestures = {
      workspace_swipe_touch = false,
    } })
    hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "default", style = "slide" })
  '';
  # Compatibility modules for existing user checkouts, without editing dotfiles.
  themeFix = path: hash: pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/e9af2ea5c12883ab108fd24672583010426108ef/examples/shells/caelestia/${path}";
    inherit hash;
  };
  phoneGestures = pkgs.linkFarm "morf-phone-gestures" [
    {
      name = "touch_contacts.lua";
      path = themeFix "shell/touch_contacts.lua" "sha256-8gV9HadCp1NePGmdR7+UKvRwjKKkT4wa1YsASAQ0rng=";
    }
    {
      name = "workspace_gesture.lua";
      path = themeFix "shell/workspace_gesture.lua" "sha256-6/yvTm4U5w+3hMLArHYwg65rVIHdOjJyiKe/Tb+oL2E=";
    }
    {
      name = "phone_repair/osk.lua";
      path = pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/paneworks/morf/e9af2ea5c12883ab108fd24672583010426108ef/library/lib/util/osk.lua";
        hash = "sha256-N8zio/785H//B7tkjHI2AT2m8l6vosw1lrAjMYWP6+w=";
      };
    }
    {
      name = "keyboard_gestures.lua";
      path = themeFix "shell/keyboard_gestures.lua" "sha256-OpcJs/9eEvYLRM/V6pCS9427H3ujq4eVfQYpmqX4oGE=";
    }
    {
      name = "phone_repair/keyboard.lua";
      path = themeFix "themes/layouts/views/keyboard.lua" "sha256-fJ/m8fXfe96EbsTOiC0ARcC/ifRO8VVet3VBHc4tH68=";
    }
    {
      name = "phone_gestures.lua";
      path = themeFix "shell/phone_gestures.lua" "sha256-rE1cwEAKyQV0jE9b7HNG/vMzN4gLgnKsMEj7yyNFsnk=";
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
