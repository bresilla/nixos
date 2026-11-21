# This machine's state as one JSON file for status.bresilla.com. Arguments: the output
# file, then the parts to include. A part that fails is null; the page shows that.
set -uo pipefail
out=$1
shift
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A unit's state, when it last ran and how that run ended.
unit() {
  systemctl show "$1" --timestamp=unix -p Id -p Description -p LoadState -p ActiveState -p SubState \
    -p Result -p ExecMainStartTimestamp -p ExecMainExitTimestamp -p ExecMainStatus |
    jq -Rn '[inputs | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}] | add // {}'
}

failed() { systemctl list-units --failed --all -o json --no-pager; }

containers() { systemctl list-units 'container@*' --all -o json --no-pager; }

timers() {
  systemctl list-timers --all -o json --no-pager | jq -c '.[]' | while read -r timer; do
    jq -n --argjson t "$timer" --argjson s "$(unit "$(jq -r .activates <<< "$timer")")" '$t + {service: $s}'
  done | jq -s .
}

# Each filesystem once, however many subvolumes of it are mounted.
disks() {
  df -B1 --output=target,source,size,used,avail -x tmpfs -x devtmpfs -x efivarfs -x overlay -x nfs4 | tail -n +2 |
    jq -Rn '[inputs | [splits(" +")] | {target: .[0], source: .[1], size: (.[2] | tonumber),
      used: (.[3] | tonumber), avail: (.[4] | tonumber)}] | sort_by(.target | length) | unique_by(.source)'
}

raid() {
  for md in /sys/block/md*/md; do
    [ -d "$md" ] || continue
    jq -n --arg name "$(basename "$(dirname "$md")")" --arg state "$(cat "$md/array_state")" \
      --arg degraded "$(cat "$md/degraded" 2> /dev/null)" --arg sync "$(cat "$md/sync_action" 2> /dev/null)" \
      --arg disks "$(cat "$md/raid_disks")" --arg level "$(cat "$md/level")" \
      '{name: $name, level: $level, state: $state, degraded: $degraded, sync: $sync, disks: $disks}'
  done | jq -s .
}

# USB drives are listed but never asked: nest's enclosure hangs for a minute on SMART.
smart() {
  lsblk -dn -o NAME,TYPE,TRAN | awk '$2 == "disk" && $1 !~ /^(mmcblk|zram|loop)/ {print $1, $3}' | while read -r dev tran; do
    if [ "$tran" = usb ]; then
      jq -n --arg dev "$dev" --arg model "$(lsblk -dn -o MODEL "/dev/$dev")" '{dev: $dev, model: $model, usb: true}'
      continue
    fi
    report=$(smartctl -j -H -A -i "/dev/$dev")
    jq --arg dev "$dev" '{dev: $dev, model: .model_name, serial: .serial_number, passed: .smart_status.passed,
      temp: .temperature.current, hours: .power_on_time.hours,
      used: .nvme_smart_health_information_log.percentage_used,
      media_errors: .nvme_smart_health_information_log.media_errors,
      spare: .nvme_smart_health_information_log.available_spare}' <<< "$report"
  done | jq -s .
}

# Read, write, flush, corruption and generation errors each btrfs filesystem has seen.
btrfs_errors() {
  for mount in $BTRFS_MOUNTS; do
    mountpoint -q "$mount" || { jq -n --arg m "$mount" '{mount: $m, mounted: false}'; continue; }
    btrfs device stats "$mount" | awk '{s += $2} END {print s + 0}' |
      jq --arg m "$mount" '{mount: $m, mounted: true, errors: .}'
  done | jq -s .
}

scrub() {
  for mount in $SCRUB_MOUNTS; do
    jq -n --arg m "$mount" --arg text "$(btrfs scrub status "$mount" 2>&1)" '{mount: $m, text: $text}'
  done | jq -s .
}

# Snapshot and copy names per share, as btrbk writes them: <share>.<YYYYMMDDTHHMM>.
backups() {
  list() { [ -d "$1" ] && find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort; }
  jq -n --arg snaps "$(list "$SNAPSHOTS")" --arg copies "$(list "$COPIES")" \
    --argjson drive "$(mountpoint -q "$COPIES" && echo true || echo false)" \
    '{drive: $drive, snapshots: ($snaps | split("\n") | map(select(. != ""))),
      copies: ($copies | split("\n") | map(select(. != "")))}'
}

units() { for u in $WATCH_UNITS; do unit "$u"; done | jq -s .; }

# Each site's certificate as it is served, and each root on disk.
certs() {
  {
    for entry in $CERTS; do
      name=${entry%%=*} address=${entry#*=}
      dates=$(timeout 10 openssl s_client -connect "$address" -servername "$name" < /dev/null 2> /dev/null |
        openssl x509 -noout -startdate -enddate -issuer 2> /dev/null)
      cert_json "$name" "$dates"
    done
    for entry in $ROOTS; do
      cert_json "${entry%%=*}" "$(openssl x509 -in "${entry#*=}" -noout -startdate -enddate -issuer 2> /dev/null)"
    done
  } | jq -s .
}
cert_json() {
  start=$(sed -n 's/^notBefore=//p' <<< "$2") end=$(sed -n 's/^notAfter=//p' <<< "$2")
  jq -n --arg name "$1" --arg issuer "$(sed -n 's/^issuer=//p' <<< "$2")" \
    --arg from "$([ -n "$start" ] && date -d "$start" +%s)" --arg until "$([ -n "$end" ] && date -d "$end" +%s)" \
    '{name: $name, issuer: $issuer, from: ($from | tonumber? // null), until: ($until | tonumber? // null)}'
}

for part in "$@"; do
  { "$part" || true; } > "$work/raw"
  jq -s --arg p "$part" '{($p): (.[0] // null)}' "$work/raw" > "$work/$part.json" 2> /dev/null ||
    jq -n --arg p "$part" '{($p): null}' > "$work/$part.json"
done
jq -n --arg host "$(uname -n)" --argjson at "$(date +%s)" '{host: $host, at: $at}' > "$work/0.json"
jq -s add "$work"/*.json > "$work/all" && install -m 0644 "$work/all" "$out"
