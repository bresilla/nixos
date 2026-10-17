# Packaged by writeShellApplication with bash, coreutils, monitor-sensor and
# the configured Hyprland. The proxy handles sensor filtering and flat poses.

rotate() {
  local transform=$1 output=${2-DSI-1} reply
  # Query inside Hyprland so Morf's current scale and monitor position survive.
  reply=$(hyprctl dispatch "function()
    local m = hl.get_monitor('DSI-1')
    assert(m, 'FP6 display is unavailable')
    hl.monitor({
      output = m.name, mode = 'preferred',
      position = string.format('%dx%d', m.x, m.y),
      scale = m.scale, transform = $transform
    })
    hl.config({input = {touchdevice = {output = '$output', transform = $transform}}})
  end") || return 1
  if [[ "$reply" != ok ]]; then
    printf 'Failed to rotate FP6: %s\n' "$reply" >&2
    return 1
  fi
}

if [[ ${1-} == --reset ]]; then
  rotate 0 ''
  exit 0
fi

export LC_ALL=C
# Line buffering is required when monitor-sensor writes to a pipe. Retain its
# PID so a failed Hyprland command also releases the accelerometer claim.
exec 3< <(exec stdbuf -oL monitor-sensor --accel)
sensor_pid=$!
trap 'kill "$sensor_pid" 2>/dev/null || true; wait "$sensor_pid" 2>/dev/null || true' EXIT
trap 'exit 0' TERM INT

last=
while IFS= read -r line <&3; do
  case "$line" in
    *'Accelerometer orientation changed: '*) orientation=${line##*: } ;;
    '=== Has accelerometer (orientation: '*)
      orientation=${line#*orientation: }
      orientation=${orientation%%,*}
      ;;
    *) continue ;;
  esac
  case "$orientation" in
    normal) transform=0 ;;
    left-up) transform=1 ;;
    bottom-up) transform=2 ;;
    right-up) transform=3 ;;
    *) continue ;;
  esac
  [[ "$transform" != "$last" ]] || continue
  rotate "$transform"
  last=$transform
  printf 'FP6 orientation: %s (display and touch transform %s)\n' "$orientation" "$transform"
done

# A disconnected/failed monitor must be restarted even if it exited with 0.
exit 1
