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
    url = "https://raw.githubusercontent.com/paneworks/morf/ae73f735f8d0abe3201e352e89afe9c54049cc60/examples/shells/caelestia/${path}";
    inherit hash;
  };
  phoneGestures = pkgs.linkFarm "morf-phone-gestures" [
    {
      name = "phone_repair/scroll.lua";
      path = pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/paneworks/morf/ae73f735f8d0abe3201e352e89afe9c54049cc60/library/lib/kit/scroll.lua";
        hash = "sha256-CNJkF/NX4ApvJN6KEfph8EQ6jjx0Nz2nfOJrHoT8Cfk=";
      };
    }
    {
      name = "themes/keyboard.lua";
      path = themeFix "themes/keyboard.lua" "sha256-OIQoUca73mu3FbGp9YGWMYMutzyUktGjMCEn/8z1Uvs=";
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
        url = "https://raw.githubusercontent.com/paneworks/morf/2b658a2f2df98d328d890289bc39fc6b3c5ac885/library/lib/util/osk.lua";
        hash = "sha256-N8zio/785H//B7tkjHI2AT2m8l6vosw1lrAjMYWP6+w=";
      };
    }
    {
      name = "keyboard_gestures.lua";
      path = themeFix "shell/keyboard_gestures.lua" "sha256-DWTxcywV3N8N9lKhVv7NwUsyt4t8NowQHrySBeI4j98=";
    }
    {
      name = "phone_repair/keyboard.lua";
      path = themeFix "themes/layouts/views/keyboard.lua" "sha256-nTlC3oooztgV3QyKcQpfEJwLXPQangJ5GDXMATIX6u4=";
    }
    {
      name = "phone_gestures.lua";
      path = themeFix "shell/phone_gestures.lua" "sha256-8m5GTOqXUEsBofefiAh/mlH3Xm0F4lByS3odccpETAY=";
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
      path = themeFix "shell/drawer.lua" "sha256-gbus1x/kgwKXXhfuwiuwQoYaEpHMG8WlYGi6gHDSJsk=";
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
      path = themeFix "themes/layouts/views/dashboard.lua" "sha256-l66HpQtBuR57jDYGFUVVjq2wfLcWQqwOCw5kJpCQh3g=";
    }
    {
      name = "phone_repair/side_panel.lua";
      path = themeFix "themes/layouts/views/side_panel.lua" "sha256-CoB/QcyznykKzbjogN5lRQWPDnV5eP8G+cEd2QWlyhc=";
    }
    {
      name = "phone_repair/bar.lua";
      path = themeFix "shell/bar.lua" "sha256-U86hX6qSm7L2Q/sCaIC57mdjBHb0EomolgMghCz0Shc=";
    }
    {
      name = "phone_repair/keyboard_controller.lua";
      path = themeFix "shell/keyboard.lua" "sha256-qg8zUBGRtnyE3ScyfVyA6DgLTaRyKNQSf5YTkP5s9EM=";
    }
    {
      name = "phone_repair/frame_host.lua";
      path = themeFix "themes/frame_host.lua" "sha256-dUX3PU38hMw/MMDdKNmuXIxA/xc4I6+VoaC5S267GGU=";
    }
    {
      name = "phone_repair/shared_keyboard.lua";
      path = themeFix "themes/keyboard.lua" "sha256-OIQoUca73mu3FbGp9YGWMYMutzyUktGjMCEn/8z1Uvs=";
    }
    {
      name = "phone_repair/dashboard_terminal.lua";
      path = themeFix "themes/layouts/views/dashboard_terminal.lua" "sha256-KnVrr+2v40DDzKL2zgmCIVEjRfQzd4tpiE5I9tSo3l0=";
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
