{ config, lib, pkgs, ... }:
let
  cage = pkgs.callPackage ./cage-phone.nix { };
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
in {
  # Cage handles display power directly while the login screen is active.
  # The compositor exits with Morf when greetd starts the user's session.
  system.build.morfGreeterCompositor = pkgs.writeShellScript "phone-greeter-compositor" ''
    export CAGE_PHONE_IDLE_SECONDS=60
    exec ${cage}/bin/cage -m last -s -- "$@"
  '';
  services.logind.settings.Login.HandlePowerKey = "lock";
  environment.systemPackages = lib.mkIf config.programs.hyprland.enable [ screen ];
  environment.etc = lib.mkIf config.programs.hyprland.enable {
    "xdg/hypr/hypridle.conf".source = lib.mkForce idleConfig;
    "xdg/hypr/hypridle.conf".text = lib.mkForce null;
  };
}
