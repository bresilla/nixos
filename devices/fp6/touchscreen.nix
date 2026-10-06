{ config, lib, pkgs, ... }:

{
  # On this FP6 the controller can enumerate at boot without producing input.
  # Rebinding it after the display is ready restored physical touch events.
  # Keep this boot workaround with the hardware, using the installed driver.
  systemd.services.fp6-touchscreen = lib.mkIf config.services.greetd.enable {
    description = "Reinitialize the FP6 touchscreen after display startup";
    wantedBy = [ "graphical.target" ];
    after = [ "greetd.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      # A rebuild may happen with the display asleep. Wait in the background
      # rather than holding up activation until someone wakes the phone.
      Type = "exec";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      driver=/sys/bus/spi/drivers/eswin_eph8621
      ready=false
      while ! "$ready"; do
        for panel in /sys/class/drm/card*-DSI-*/enabled; do
          if [[ -L "$driver/spi0.0" && -r "$panel" && $(<"$panel") == enabled ]]; then
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
