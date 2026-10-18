{ config, lib, pkgs, ... }:
let
  user = config.bresilla.user.name;
  # Armada's fake suspend. A real suspend cuts the USB-C port, and the root
  # drive on it does not come back, so sleep only blanks and quiets the device
  # until the power key. Drop this once NixOS runs from internal storage.
  fakeSuspend = pkgs.writeShellApplication {
    name = "odin3-fake-suspend";
    runtimeInputs = with pkgs; [
      coreutils
      evtest
      procps
      util-linux
      config.programs.gamescope.package
      wireplumber
    ];
    text = ''
      uid=$(id -u ${user})
      runtime=/run/user/$uid
      as_user() {
        runuser -u ${user} -- env XDG_RUNTIME_DIR="$runtime" "$@"
      }
      screen() {
        local socket done=1
        for socket in "$runtime"/gamescope-*; do
          [[ -S $socket && $(basename "$socket") =~ ^gamescope-[0-9]+$ ]] || continue
          as_user env GAMESCOPE_WAYLAND_DISPLAY="$(basename "$socket")" \
            gamescopectl drm_sleep_internal_screen "$1" && done=0
        done
        # Outside gamescope, the backlight blanks the panel.
        if (( done )); then
          for power in /sys/class/backlight/*/bl_power; do
            echo $(( $1 ? 4 : 0 )) > "$power" || true
          done
        fi
      }
      power_key() {
        local event
        for event in /dev/input/event*; do
          case "$(cat "/sys/class/input/$(basename "$event")/device/name" 2>/dev/null)" in
            *pwrkey*|*[Pp]ower\ [Bb]utton*) echo "$event"; return 0 ;;
          esac
        done
        return 1
      }

      key=$(power_key || true)
      as_user wpctl set-mute @DEFAULT_AUDIO_SINK@ 1 || true
      # Hold every other input, so the controls do nothing while it sleeps.
      for event in /dev/input/event*; do
        [[ $event == "$key" ]] || evtest --grab "$event" > /dev/null 2>&1 &
      done
      screen 1

      # Wake on the next power press; ignore the release of the one that slept.
      start=$SECONDS
      exec 3< <(evtest --grab "$key" 2> /dev/null)
      while IFS= read -r -u 3 line; do
        [[ $line == *"(KEY_POWER), value 1"* ]] && (( SECONDS - start >= 1 )) && break
      done
      exec 3<&-

      pkill -9 -f 'evtest --grab' || true
      screen 0
      as_user wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 || true
    '';
  };
in
{
  # The power key and Steam's idle sleep both reach systemd-suspend.service.
  systemd.services.systemd-suspend.serviceConfig = lib.mkIf (config.bresilla.odin3.storage == "usb") {
    ExecStart = [
      ""
      (lib.getExe fakeSuspend)
    ];
    TimeoutStartSec = "infinity";
  };
}
