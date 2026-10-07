{ config, pkgs, ... }:
let
  action = pkgs.writeShellApplication {
    name = "phone-gesture";
    runtimeInputs = [ config.programs.hyprland.package config.bresilla.programs.morf.package
      pkgs.jq pkgs.coreutils ];
    text = ''
      case "''${1:-}" in
        workspace-next|workspace-previous|dashboard|top|keyboard) ;;
        *) exit 2 ;;
      esac
      # Let Wayland deliver the final contacts before querying Morf's context.
      sleep 0.05
      # Global input must never act on the desktop behind a session lock.
      hyprctl -j locked | jq -e '.locked == false' >/dev/null || exit 0
      timeout 3 morf -i "$WAYLAND_DISPLAY" ipc call phone-gesture "$1" >/dev/null
    '';
  };
  runner = pkgs.writeShellApplication {
    name = "phone-gestures";
    runtimeInputs = [ pkgs.lisgd config.programs.hyprland.package pkgs.jq pkgs.systemd
      pkgs.coreutils pkgs.gnugrep ];
    text = ''
      export PHONE_GESTURE_ACTION=${action}/bin/phone-gesture
      ${builtins.readFile ./phone-gestures.sh}
    '';
  };
in {
  environment.systemPackages = [ pkgs.lisgd ];
  systemd.user.services.morf.environment.CAELESTIA_GESTURE_DRIVER = "lisgd";
  systemd.user.services.phone-gestures = {
    description = "Phone edge swipes through lisgd";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" "morf.service" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${runner}/bin/phone-gestures";
      Restart = "on-failure";
      RestartSec = 2;
      TimeoutStopSec = 5;
    };
  };
}
