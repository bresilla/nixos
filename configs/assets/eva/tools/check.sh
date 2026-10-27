#!/bin/sh
# The shell, lock screen and greeter, each loaded headless by `morf check`:
# no errors, and an engine that meets morf.lua.
#
# MORF is the binary (default: morf on PATH).
set -eu
cd "$(dirname "$0")/.."
morf=${MORF:-morf}
for role in shell lock greet; do
  set -- "$role/init.lua" --no-dbus --isolate --after 0
  [ "$role" = lock ] && set -- "$@" -- window preview
  EVA_DRY_RUN=1 "$morf" check "$@"
done
