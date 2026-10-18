{ lib, pkgs, ... }:

let
  # Armada's armada-powerd fan loop with its balanced profile: no thermal zone
  # drives the pwm-fan, so without this it stays where the bootloader left it.
  fan = pkgs.writeShellApplication {
    name = "odin3-fan";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
    ];
    text = ''
      # Armada's "moderate" curve, °C:pwm, ascending.
      curve=(0:51 55:51 72:77 78:102 84:153 90:204 96:255)
      min=51 max=255 up=36 down=6

      hwmon=
      for h in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$h/name")" = pwmfan ] && hwmon=$h
      done
      [ -n "$hwmon" ] || { echo "odin3-fan: no pwmfan hwmon" >&2; exit 1; }

      zones=()
      for z in /sys/class/thermal/thermal_zone*; do
        case "$(cat "$z/type")" in cpu*|gpu*|video*|mem*) zones+=("$z/temp") ;; esac
      done

      target() {
        local t=$1 i lo hi lt lp ht hp
        for ((i = 1; i < ''${#curve[@]}; i++)); do
          lo=''${curve[i-1]} hi=''${curve[i]}
          lt=''${lo%:*} lp=''${lo#*:} ht=''${hi%:*} hp=''${hi#*:}
          if (( t <= ht )); then
            (( t <= lt )) && { echo "$lp"; return; }
            echo $(( lp + (hp - lp) * (t - lt) / (ht - lt) ))
            return
          fi
        done
        echo "''${curve[-1]#*:}"
      }

      # Mode 3 lets pwm-fan cut the fan supply at duty 0, as Armada sets it.
      echo 3 > "$hwmon/pwm1_enable"
      pwm=$(cat "$hwmon/pwm1")
      while true; do
        # Mean of the three hottest control zones, in °C.
        temp=$(cat "''${zones[@]}" 2>/dev/null | sort -rn | awk 'NR <= 3 { s += $1; n++ } END { print int(s / n / 1000) }')
        want=$(target "$temp")
        if (( want > pwm )); then
          pwm=$(( want < pwm + up ? want : pwm + up ))
        else
          pwm=$(( want > pwm - down ? want : pwm - down ))
        fi
        (( pwm < min )) && pwm=$min
        (( pwm > max )) && pwm=$max
        echo "$pwm" > "$hwmon/pwm1"
        sleep 3
      done
    '';
  };
in
{
  systemd.services.odin3-fan = {
    description = "Odin 3 fan curve";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = lib.getExe fan;
      Restart = "always";
      RestartSec = 5;
    };
  };
}
