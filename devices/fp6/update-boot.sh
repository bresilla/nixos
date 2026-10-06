#!/usr/bin/env bash
set -euo pipefail

check_only=false
if [[ "${1:-}" == --check ]]; then check_only=true; shift; fi
[[ $# == 1 ]] || { echo "Usage: update-boot.sh [--check] boot.img" >&2; exit 2; }
image="$1"
[[ $EUID == 0 ]] || { echo "Run on the FP6 as root." >&2; exit 1; }
tr '\0' '\n' < /proc/device-tree/compatible | grep -Fxq 'fairphone,fp6'
partition=/dev/disk/by-partlabel/boot_a
[[ -b "$partition" && -f "$image" ]]
[[ "$(blockdev --getsize64 "$partition")" == 100663296 ]]
[[ "$(stat -c %s "$image")" == 100663296 ]]
[[ "$(head -c 8 "$image")" == 'ANDROID!' ]]
[[ "$(tail -c 64 "$image" | head -c 4)" == 'AVBf' ]]
if $check_only; then echo "FP6 boot image and boot_a checks passed."; exit 0; fi
checksum="$(sha256sum "$image" | cut -d ' ' -f 1)"
echo "Updating this FP6's boot_a; preserving userdata and all other partitions."
dd if="$image" of="$partition" bs=4M conv=fsync status=progress
printf '%s  %s\n' "$checksum" "$partition" | sha256sum --check
sync
echo "Boot image installed and read back successfully. Reboot when ready."
