#!/bin/sh
# Every spec under tests/ through `morf test`, in parallel shards, with the
# XDG folders and the buses kept away from the person's own.
#
#   tools/test.sh [SPEC ...]
#
# MORF is the binary (default: morf on PATH), JOBS the shard count (default:
# the CPUs, at most 8).
set -eu
cd "$(dirname "$0")/.."
morf=${MORF:-morf}
jobs=${JOBS:-$(nproc 2>/dev/null || echo 4)}
[ "$jobs" -gt 8 ] && jobs=8

MORF_FONT_PATH="$PWD/shell/fonts${MORF_FONT_PATH:+:$MORF_FONT_PATH}"
# A desk with a keyboard, as the specs are written for, on any machine.
EVA_INPUT_DEVICES=${EVA_INPUT_DEVICES:-$PWD/tests/fixtures/input-devices}
export MORF_FONT_PATH EVA_INPUT_DEVICES

scratch=$(mktemp -d "${TMPDIR:-/tmp}/eva-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/state" "$scratch/cache" "$scratch/config" "$scratch/run"
chmod 700 "$scratch/run"

if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else ls tests/*_spec.lua; fi > "$scratch/specs"
split -n "l/$jobs" -d "$scratch/specs" "$scratch/shard."

for shard in "$scratch"/shard.*; do
  [ -s "$shard" ] || continue
  (
    XDG_STATE_HOME="$scratch/state" XDG_CACHE_HOME="$scratch/cache" \
    XDG_CONFIG_HOME="$scratch/config" XDG_RUNTIME_DIR="$scratch/run" \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent \
    DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent \
      "$morf" test --no-dbus $(cat "$shard") > "$shard.tap" 2>&1 || true
  ) &
done
wait

status=0
for tap in "$scratch"/shard.*.tap; do
  if ! grep -q '^# [0-9]* passed' "$tap"; then
    echo "a shard stopped before its summary:" >&2
    tail -n 20 "$tap" >&2
    status=1
  fi
done
grep -h -A3 '^not ok' "$scratch"/shard.*.tap || true
grep -h '^# [0-9]* passed' "$scratch"/shard.*.tap | awk '
  { passed += $2; failed += $4; skipped += $6 }
  END { printf "eva: %d passed, %d failed, %d skipped\n", passed, failed, skipped; exit failed > 0 }
' || status=1
exit "$status"
