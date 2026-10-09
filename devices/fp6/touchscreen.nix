{ config, lib, pkgs, ... }:

{
  # On this FP6 the controller can enumerate at boot without producing input.
  # Rebinding it after the display is ready restored physical touch events.
  # Keep this boot workaround with the hardware, using the installed driver.
  systemd.services.fp6-touchscreen = lib.mkIf config.services.greetd.enable {
    description = "Reinitialize the FP6 touchscreen after display startup";
    wantedBy = [ "graphical.target" ];
    after = [ "greetd.service" ];
    path = [ pkgs.coreutils pkgs.jq pkgs.util-linux config.programs.hyprland.package ];
    serviceConfig = {
      # A rebuild may happen with the display asleep. Wait in the background
      # rather than holding up activation until someone wakes the phone.
      Type = "exec";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      driver=/sys/bus/spi/drivers/eswin_eph8621

      compositor_ready() {
        local session user runtime socket instance monitors
        session=$(loginctl show-seat seat0 --property=ActiveSession --value) || return 1
        [[ -n "$session" ]] || return 1
        user=$(loginctl show-session "$session" --property=Name --value) || return 1
        [[ -n "$user" ]] || return 1
        runtime=$(loginctl show-user "$user" --property=RuntimePath --value) || return 1
        [[ -d "$runtime" ]] || return 1

        for socket in "$runtime"/hypr/*/.socket.sock; do
          [[ -S "$socket" ]] || continue
          instance=$(basename "$(dirname "$socket")")
          monitors=$(timeout 2s runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" \
            hyprctl -i "$instance" -j monitors 2>/dev/null) || continue
          if jq -e 'any(.[]; (.name | startswith("DSI-")) and .dpmsStatus
              and (.disabled | not) and .width > 0 and .height > 0)' \
              >/dev/null <<< "$monitors"; then
            return 0
          fi
        done
        return 1
      }

      ready=false
      while ! "$ready"; do
        for panel in /sys/class/drm/card*-DSI-*/enabled; do
          # The boot framebuffer already reports enabled before Hyprland starts.
          # Wait for the active compositor to report the phone display powered on.
          if [[ -L "$driver/spi0.0" && -r "$panel" && $(<"$panel") == enabled ]] \
              && compositor_ready; then
            ready=true
            break
          fi
        done
        if "$ready"; then break; fi
        sleep 1
      done

      # Restore the binding even if the service is stopped during the reset.
      trap 'if [[ ! -L "$driver/spi0.0" ]]; then printf spi0.0 > "$driver/bind"; fi' EXIT
      printf spi0.0 > "$driver/unbind"
      sleep 1
      printf spi0.0 > "$driver/bind"
      echo "FP6 touchscreen reinitialized"
    '';
  };
}
