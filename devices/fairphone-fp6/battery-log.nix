{ pkgs, ... }:
let
  # One CSV row per run: what the battery is doing, whether the phone has
  # slept since boot, and which process was busiest over one second.
  battery-log = pkgs.writeShellApplication {
    name = "fp6-battery-log";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      getconf
      procps
    ];
    text = ''
      bat=/sys/class/power_supply/qcom-battmgr-bat
      log=/var/lib/battery-log/battery.csv
      if [ ! -s "$log" ]; then
        echo "time,capacity,status,current_ma,power_mw,voltage_mv,temp_c,suspends,fingerprintd_cpu_s,top_cpu,top_process" > "$log"
      fi
      read_bat() { cat "$bat/$1" 2>/dev/null || echo 0; }
      fpd=$(pgrep -x fingerprintd | head -n1 || true)
      fpd_cpu=""
      if [ -n "$fpd" ]; then
        fpd_cpu=$(awk -v hz="$(getconf CLK_TCK)" '{ print int(($14 + $15) / hz) }' "/proc/$fpd/stat")
      fi
      # The second sample covers the one-second interval, not process lifetime.
      top=$(top -b -n2 -d1 -o %CPU -w 512 | awk '/^ *PID/ { n++; next } n == 2 && $12 != "top" { print $9 "," $12; exit }')
      current=$(( $(read_bat current_now) / 1000 ))
      voltage=$(( $(read_bat voltage_now) / 1000 ))
      # battmgr's power_now is several times current x voltage; derive it.
      echo "$(date -Iseconds),$(read_bat capacity),$(read_bat status),$current,$(( current * voltage / 1000 )),$voltage,$(( $(read_bat temp) / 10 )),$(cat /sys/power/suspend_stats/success),$fpd_cpu,$top" >> "$log"
    '';
  };
in
{
  environment.systemPackages = [ battery-log ];
  systemd.services.fp6-battery-log = {
    description = "Log FP6 battery drain";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${battery-log}/bin/fp6-battery-log";
      StateDirectory = "battery-log";
      StateDirectoryMode = "0755";
      UMask = "0022";
    };
  };
  # Calendar time, so a run missed while suspended happens on resume and the
  # gap between rows shows how long the phone slept.
  systemd.timers.fp6-battery-log = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      Persistent = true;
    };
  };
}
