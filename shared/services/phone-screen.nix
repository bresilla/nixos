{ config, lib, pkgs, ... }:
let
  hyprland = config.programs.hyprland.package;
  dpms = pkgs.writeShellScriptBin "phone-dpms" ''
    exec ${config.system.build.hyprlandIdleDpms} "$@"
  '';
  screen = pkgs.writeShellApplication {
    name = "phone-screen";
    runtimeInputs = [ hyprland dpms pkgs.coreutils pkgs.gawk pkgs.jq pkgs.systemd pkgs.util-linux ];
    text = builtins.readFile ./phone-screen.sh;
  };
  idleConfig = pkgs.writeText "phone-hypridle.conf" ''
    general {
      lock_cmd = ${screen}/bin/phone-screen toggle
      before_sleep_cmd = ${screen}/bin/phone-screen off
      after_sleep_cmd = ${screen}/bin/phone-screen wake
      inhibit_sleep = 3
    }
    listener {
      timeout = 1
      on-resume = ${screen}/bin/phone-screen wake
    }
    listener {
      timeout = 60
      on-timeout = ${screen}/bin/phone-screen off
      on-resume = ${screen}/bin/phone-screen wake
    }
  '';
  greeterSession = pkgs.writeShellScript "phone-greeter-session" ''
    ${config.services.hypridle.package}/bin/hypridle --config ${idleConfig} &
    idle=$!
    trap 'kill "$idle" 2>/dev/null || true' EXIT
    ${config.system.build.morfLauncher}/bin/morf greet
    status=$?
    ${hyprland}/bin/hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 \
      || ${hyprland}/bin/hyprctl dispatch exit >/dev/null 2>&1
    exit "$status"
  '';
  # Cage does not expose output power management. Use a dedicated minimal
  # Hyprland session for the phone greeter, with no user desktop configuration.
  greeterConfig = pkgs.writeText "phone-greeter.lua" ''
    hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
    hl.config({
      misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        background_color = "rgb(000000)",
        -- greetd owns this session; there is no desktop launcher/watchdog.
        disable_watchdog_warning = true,
        disable_xdg_env_checks = true,
        key_press_enables_dpms = false,
        mouse_move_enables_dpms = false,
      },
      ecosystem = { no_update_news = true, no_donation_nag = true },
      animations = { enabled = false },
      general = { border_size = 0, gaps_in = 0, gaps_out = 0 },
      input = { kb_layout = "us" },
    })
    -- logind does not send Lock to sessions of class greeter.
    hl.bind("XF86PowerOff", hl.dsp.exec_cmd("${screen}/bin/phone-screen toggle"), { locked = true })
    hl.on("hyprland.start", function()
      hl.exec_cmd("${greeterSession}")
    end)
  '';
in lib.mkIf config.programs.hyprland.enable {
  services.logind.settings.Login.HandlePowerKey = "lock";
  environment.systemPackages = [ screen ];
  environment.etc."xdg/hypr/hypridle.conf".source = lib.mkForce idleConfig;
  environment.etc."xdg/hypr/hypridle.conf".text = lib.mkForce null;
  system.build.morfGreeterCompositor = pkgs.writeShellScript "phone-greeter-compositor" ''
    export MORF_PHONE_GREETER=1
    # greetd attaches the child to its VT. Capture the compositor's output
    # here, including early startup messages, while retaining diagnostics.
    exec ${pkgs.systemd}/bin/systemd-cat --identifier=morf-greeter -- \
      ${hyprland}/bin/Hyprland --config ${greeterConfig}
  '';
}
