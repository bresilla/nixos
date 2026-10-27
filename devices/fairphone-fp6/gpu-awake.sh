#!/usr/bin/env bash
# Under a full Nix build the GPU's GMU fails to wake from runtime suspend, which
# hangs the GPU until a reboot; the update keeps it powered while it runs.
set -euo pipefail
mode="${1:?Usage: gpu-awake.sh on|auto}"
for control in /sys/bus/platform/devices/*.gpu/power/control; do
  echo "$mode" > "$control"
done
