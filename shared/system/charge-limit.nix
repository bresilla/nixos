{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.features.system.chargeLimit;
in
{
  options.bresilla.features.system.chargeLimit = lib.mkOption {
    type = lib.types.nullOr (lib.types.ints.between 50 100);
    default = null;
    example = 80;
    description = "Percentage the battery stops charging at; charging resumes 5 below it.";
  };

  config = lib.mkIf (cfg != null) {
    # Qualcomm battery firmware puts back the limit Android last stored some time
    # after boot, so keep writing until it holds twice.
    systemd.services.charge-limit = {
      description = "Charge the battery up to ${toString cfg}%";
      wantedBy = [ "multi-user.target" ];
      before = [ "upower.service" ];
      path = [ pkgs.coreutils ];
      serviceConfig.Type = "oneshot";
      script = ''
        held=0
        for _ in $(seq 60); do
          found=0 ok=1
          for bat in /sys/class/power_supply/*; do
            [ -w "$bat/charge_control_end_threshold" ] || continue
            found=1
            if [ "$(cat "$bat/charge_control_end_threshold")" != ${toString cfg} ] ||
               [ "$(cat "$bat/charge_control_start_threshold" 2>/dev/null || echo ${toString (cfg - 5)})" != ${toString (cfg - 5)} ]; then
              ok=0
              # Start first when lowering: the firmware rejects a start above the end.
              echo ${toString (cfg - 5)} > "$bat/charge_control_start_threshold" 2>/dev/null || true
              echo ${toString cfg} > "$bat/charge_control_end_threshold" || true
              echo ${toString (cfg - 5)} > "$bat/charge_control_start_threshold" 2>/dev/null || true
            fi
          done
          (( found )) || { echo "no battery with a charge threshold"; exit 0; }
          if (( ok )); then held=$((held + 1)); (( held >= 2 )) && exit 0; else held=0; fi
          sleep 2
        done
        echo "charge limit did not hold" >&2
        exit 1
      '';
    };
  };
}
