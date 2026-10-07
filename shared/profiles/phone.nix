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
    -- Morf has already animated the preview to its destination on release.
    -- A second compositor animation would slide the same workspace again.
    hl.animation({ leaf = "workspaces", enabled = false })
  '';
  # Compatibility modules for existing user checkouts, without editing dotfiles.
  themeFix = path: hash: pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/924161f7710ee2333fbec03b12146b1779674c7b/examples/shells/caelestia/${path}";
    inherit hash;
  };
  phoneGestures = pkgs.linkFarm "morf-phone-gestures" [
    {
      name = "themes/keyboard.lua";
      path = themeFix "themes/keyboard.lua" "sha256-wiyIVX0k4k0ArtMbkmkrFcvJN4r5oADSSpsFWe37l6I=";
    }
    {
      name = "themes/touch_contacts.lua";
      path = themeFix "themes/touch_contacts.lua" "sha256-8gV9HadCp1NePGmdR7+UKvRwjKKkT4wa1YsASAQ0rng=";
    }
    {
      name = "phone_repair/responsive.lua";
      path = themeFix "shell/responsive.lua" "sha256-DzDr8zCI7F3E1ziCmdiFMd6rf8n7iWYqCK5AZftAXCI=";
    }
    {
      name = "touch_contacts.lua";
      path = themeFix "shell/touch_contacts.lua" "sha256-75FTtdDiJSy9OdyqfD1JlvahzfK8gRd7F2Ali6jLK3A=";
    }
    {
      name = "workspace_gesture.lua";
      path = themeFix "shell/workspace_gesture.lua" "sha256-ItEzTFNgrEqNsZNLhy42MktGynq7ZwRy/BvOxjuccvI=";
    }
    {
      name = "phone_repair/osk.lua";
      path = pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/paneworks/morf/924161f7710ee2333fbec03b12146b1779674c7b/library/lib/util/osk.lua";
        hash = "sha256-N8zio/785H//B7tkjHI2AT2m8l6vosw1lrAjMYWP6+w=";
      };
    }
    {
      name = "keyboard_gestures.lua";
      path = themeFix "shell/keyboard_gestures.lua" "sha256-+9ReidCbyL4ChmvHvXPq1y942+rwNJheSp5XLdCvl9s=";
    }
    {
      name = "phone_repair/keyboard.lua";
      path = themeFix "themes/layouts/views/keyboard.lua" "sha256-nTlC3oooztgV3QyKcQpfEJwLXPQangJ5GDXMATIX6u4=";
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
      path = themeFix "themes/layouts/views/dashboard.lua" "sha256-ILNmByLWET8V1Og0ZcJAjMRF9XDC1RhrX29R4V8iy6I=";
    }
    {
      name = "phone_repair/side_panel.lua";
      path = themeFix "themes/layouts/views/side_panel.lua" "sha256-CoB/QcyznykKzbjogN5lRQWPDnV5eP8G+cEd2QWlyhc=";
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
