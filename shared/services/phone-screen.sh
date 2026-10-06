set -euo pipefail

action=${1:?expected off, wake or toggle}
case "$action" in off|wake|toggle) ;; *) exit 2 ;; esac
state="${XDG_RUNTIME_DIR:?}/phone-screen-${HYPRLAND_INSTANCE_SIGNATURE:?}"
exec 9>"$state.lock"
flock 9

now=$(awk '{printf "%.0f", $1 * 1000}' /proc/uptime)
last_wake=0
if [[ -r "$state.wake" ]]; then read -r last_wake < "$state.wake"; fi
powered=$(hyprctl -j monitors | jq -er 'if length == 0 then error("no outputs") else any(.[]; .dpmsStatus != false) end | tostring')

wake() {
  if [[ "$powered" == false ]]; then
    phone-dpms on
    printf '%s\n' "$now" > "$state.wake"
  fi
}

if [[ "$action" == wake ]]; then wake; exit; fi
if [[ "$action" == toggle ]]; then
  if [[ "$powered" == false ]]; then wake; exit; fi
  # The same power press can deliver both idle-resume and logind Lock.
  # Whichever arrives first wakes the display; the second must not reblank it.
  if (( now - last_wake < 1000 )); then exit; fi
  sleep 0.25
fi

locked() { hyprctl -j locked | jq -e '.locked == true' >/dev/null; }
if ! locked; then
  systemctl --user start morf-idle-lock.service
  # A started process is not proof of a lock. Wait for the compositor to
  # confirm it before blanking; a failed locker leaves the display visible.
  for ((attempt = 0; attempt < 150; attempt++)); do
    locked && break
    systemctl --user is-active --quiet morf-idle-lock.service || exit 1
    sleep 0.2
  done
  locked || { echo 'Morf did not acquire the session lock' >&2; exit 1; }
fi
phone-dpms off
