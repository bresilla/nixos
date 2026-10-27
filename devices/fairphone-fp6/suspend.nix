{ config, lib, pkgs, ... }:
let
  # Seconds the display must stay blanked before the phone sleeps. A wake
  # that leaves it blanked, such as a charger event, restarts the count.
  delay = 60;
  autosuspend = pkgs.writeShellApplication {
    name = "fp6-autosuspend";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      systemd
    ];
    text = ''
      screen_on() {
        local power
        for power in /sys/class/backlight/*/bl_power; do
          [[ $(cat "$power") == 0 ]] && return 0
        done
        return 1
      }
      # Music with the display off, and call audio, keep a PCM running.
      audio_running() {
        grep -qs 'state: RUNNING' /proc/asound/card*/pcm*/sub*/status
      }
      suspends() { cat /sys/power/suspend_stats/success; }

      blank_since=$SECONDS
      last=$(suspends)
      while sleep 10; do
        now=$(suspends)
        if [[ $now != "$last" ]] || screen_on || audio_running; then
          last=$now
          blank_since=$SECONDS
          continue
        fi
        if (( SECONDS - blank_since >= ${toString delay} )); then
          # Inhibitors such as an open call may refuse; try again later.
          systemctl suspend || true
          blank_since=$SECONDS
        fi
      done
    '';
  };
in
{
  # Deep sleep wakes again within two seconds on this SoC; s2idle stays down
  # and the power key wakes it.
  systemd.sleep.settings.Sleep.MemorySleepMode = "s2idle";

  systemd.services.fp6-autosuspend = {
    description = "Suspend the FP6 while its display is blanked";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = lib.getExe autosuspend;
      Restart = "always";
      RestartSec = 10;
    };
  };

  # The modem keeps running while the host sleeps. A full reset on resume
  # would re-probe it and drop the IMS registration.
  systemd.services.ModemManager.serviceConfig.ExecStart = lib.mkIf config.networking.modemmanager.enable [
    ""
    "${config.networking.modemmanager.package}/sbin/ModemManager --test-quick-suspend-resume"
  ];
}
