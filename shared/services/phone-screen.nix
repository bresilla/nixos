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
  makeIdleConfig = timeout: pkgs.writeText "phone-hypridle.conf" ''
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
    ${lib.optionalString (timeout > 0) ''
      listener {
        timeout = ${toString timeout}
        on-timeout = ${screen}/bin/phone-screen off
        on-resume = ${screen}/bin/phone-screen wake
      }
    ''}
  '';
  idleConfig = makeIdleConfig config.bresilla.services.phoneScreen.idleTimeout;
  greeterIdleConfig = makeIdleConfig 60;
in {
  options.bresilla.services.phoneScreen.idleTimeout = lib.mkOption {
    type = lib.types.ints.unsigned;
    default = 60;
    description = "Seconds before locking and blanking a phone session; zero disables automatic locking.";
  };
  config = lib.mkIf config.programs.hyprland.enable {
    services.logind.settings.Login.HandlePowerKey = "lock";
    environment.systemPackages = [ screen ];
    environment.etc."xdg/hypr/hypridle.conf".source = lib.mkForce idleConfig;
    environment.etc."xdg/hypr/hypridle.conf".text = lib.mkForce null;
    bresilla.services.morf.greeter = {
      environment.MORF_PHONE_GREETER = "1";
      sessionSetup = ''
        ${config.services.hypridle.package}/bin/hypridle --config ${greeterIdleConfig} &
        idle=$!
        trap 'kill "$idle" 2>/dev/null || true' EXIT
      '';
      extraConfig = ''
        hl.config({ misc = {
          key_press_enables_dpms = false,
          mouse_move_enables_dpms = false,
        } })
        -- logind does not send Lock to sessions of class greeter.
        hl.bind("XF86PowerOff", hl.dsp.exec_cmd("${screen}/bin/phone-screen toggle"), { locked = true })
      '';
    };
  };
}
