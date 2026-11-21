# This machine's state as one JSON file for status.bresilla.com. Arguments: the output
# file, then the parts to include. A part that fails is null; the page shows that.
set -uo pipefail
out=$1
shift
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A unit's state, when it last ran and how that run ended; a second argument names a container.
unit() {
  systemctl ${2:+-M "$2"} show "$1" --timestamp=unix -p Id -p Description -p LoadState -p ActiveState -p SubState \
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

running() { machinectl list --no-legend | awk '{print $1}'; }

# The timers inside each running container, which the host's own list never shows.
inner_timers() {
  for m in $(running); do
    systemctl -M "$m" list-timers --all -o json --no-pager | jq -c '.[]' | while read -r timer; do
      jq -n --arg m "$m" --argjson t "$timer" --argjson s "$(unit "$(jq -r .activates <<< "$timer")" "$m")" \
        '$t + {machine: $m, service: $s}'
    done
  done | jq -s .
}

# Each container's memory, CPU time, restarts and how long it has been up.
container_stats() {
  systemctl list-units 'container@*' --all -o json --no-pager | jq -r '.[].unit' | while read -r u; do
    systemctl show "$u" --timestamp=unix -p MemoryCurrent -p MemoryPeak -p CPUUsageNSec -p NRestarts \
      -p ActiveState -p ActiveEnterTimestamp -p TasksCurrent |
      jq -Rn --arg u "$u" '[inputs | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}] | add + {unit: $u}'
  done | jq -s .
}

# Uptime, load, memory and the hottest CPU sensor.
vitals() {
  read -r up _ < /proc/uptime
  read -r l1 l5 l15 _ < /proc/loadavg
  temp=$(for h in /sys/class/hwmon/hwmon*; do
    case "$(cat "$h/name")" in k10temp|coretemp) cat "$h"/temp*_input ;; esac
  done 2> /dev/null | sort -n | tail -1)
  awk '{print $1, $2 * 1024}' /proc/meminfo | jq -Rn '[inputs | split(" ") | {(.[0] | rtrimstr(":")): (.[1] | tonumber)}] | add' > "$work/mem"
  jq -n --argjson up "${up%.*}" --arg l1 "$l1" --arg l5 "$l5" --arg l15 "$l15" --arg temp "$temp" \
    --arg cpus "$(nproc)" --arg kernel "$(uname -r)" --arg system "$(basename "$(readlink /run/current-system)")" \
    --slurpfile mem "$work/mem" \
    '{uptime: $up, load: [$l1, $l5, $l15] | map(tonumber), cpus: ($cpus | tonumber), kernel: $kernel, system: $system,
      temp: (if $temp == "" then null else ($temp | tonumber) / 1000 end),
      mem: {total: $mem[0].MemTotal, available: $mem[0].MemAvailable, swap: $mem[0].SwapTotal, swap_free: $mem[0].SwapFree}}'
}

# Paths and their size from Nix's own database, and what each nix-gc run freed.
nix_store() {
  jq -n --argjson db "$(sqlite3 -json "file:/nix/var/nix/db/db.sqlite?mode=ro" \
      'SELECT COUNT(*) AS paths, COALESCE(SUM(narSize), 0) AS size FROM ValidPaths' | jq '.[0]')" \
    --arg gc "$(journalctl -u nix-gc.service --since -60d -o short-unix --no-pager | grep -E 'freed|deleted' | tail -30)" \
    '$db + {gc: ($gc | split("\n") | map(select(. != "") | capture("^(?<at>[0-9]+)[^ ]* [^:]*: (?<text>.*)$")
      | {at: (.at | tonumber), text})) }'
}

# The binary cache's own numbers, read from attic's database, and its cleanup runs.
cache_stats() {
  db="file:$CACHE_DB?mode=ro"
  q() { sqlite3 -cmd ".timeout 10000" -json "$db" "$1"; }
  jq -n --argjson caches "$(q "SELECT c.name, COUNT(o.id) AS objects, COALESCE(SUM(n.nar_size), 0) AS size,
        MAX(o.created_at) AS newest FROM cache c LEFT JOIN object o ON o.cache_id = c.id
        LEFT JOIN nar n ON n.id = o.nar_id WHERE c.deleted_at IS NULL GROUP BY c.id ORDER BY c.name")" \
    --argjson chunks "$(q "SELECT state, COUNT(*) AS count, COALESCE(SUM(file_size), 0) AS size FROM chunk GROUP BY state")" \
    --argjson nars "$(q "SELECT COUNT(*) AS count, COALESCE(SUM(nar_size), 0) AS size,
        SUM(holders_count = 0) AS unheld FROM nar")" \
    --argjson week "$(q "SELECT COUNT(*) AS objects, COALESCE(SUM(n.nar_size), 0) AS size FROM object o
        JOIN nar n ON n.id = o.nar_id WHERE o.created_at > datetime('now', '-7 days')")" \
    --arg gc "$(journalctl -M "$CACHE_MACHINE" -u attic-gc.service --since -30d -o short-unix --no-pager |
        grep -E 'Starting|Finished|Failed|deleting:|deleted chunks left' | tail -400)" \
    '{caches: $caches, chunks: $chunks, nars: $nars[0], week: $week[0],
      gc: ($gc | split("\n") | map(select(. != "") | capture("^(?<at>[0-9]+)[^ ]* [^:]*: (?<text>.*)$")
        | {at: (.at | tonumber), text}))}'
}

# The pins per cache, as the cache's own page serves them.
pins() { curl -sf --max-time 15 "$PINS_URL" | jq '[.[] | {name, caches, path: .lastRevision.storePath}]'; }

# Each top-level share, and what btrbk's snapshots of it hold that nothing else does.
shares_du() {
  du_raw() { btrfs filesystem du -s --raw "$@" 2> /dev/null | tail -n +2; }
  {
    for s in "$DATA_TOP"/@*; do
      du_raw "$s" | awk -v n="$(basename "$s")" '{print "{\"share\":\"" n "\",\"total\":" $1 ",\"exclusive\":" $2 ",\"shared\":" $3 "}"}'
    done | jq -s . > "$work/live"
    for s in "$DATA_TOP"/@*; do
      n=$(basename "$s")
      set -- "$DATA_TOP/.snapshots/$n".*
      [ -e "$1" ] || continue
      du_raw "$@" | awk -v n="$n" '{c++; e += $2} END {print "{\"share\":\"" n "\",\"count\":" c ",\"exclusive\":" e + 0 "}"}'
    done | jq -s . > "$work/snaps"
    drive=${DRIVE:-/nonexistent}
    for s in "$drive"/@*.*; do [ -e "$s" ] && basename "$s"; done | sed 's/\..*//' | sort -u | while read -r n; do
      du_raw "$drive/$n".* | awk -v n="$n" '{c++; t = $1; e += $2} END {print "{\"share\":\"" n "\",\"count\":" c ",\"newest\":" t + 0 ",\"exclusive\":" e + 0 "}"}'
    done | jq -s . > "$work/drive"
    jq -n --slurpfile live "$work/live" --slurpfile snaps "$work/snaps" --slurpfile drive "$work/drive" \
      '{live: $live[0], snapshots: $snaps[0], drive: $drive[0]}'
  }
}

# Each container's own disk, on the host's container filesystem.
container_disk() {
  for m in /var/lib/nixos-containers/*/; do
    n=$(basename "$m")
    du -sxb "$m" 2> /dev/null | awk -v n="$n" '{print "{\"name\":\"" n "\",\"size\":" $1 "}"}'
  done | jq -s .
}

# Each filesystem once, however many subvolumes of it are mounted: by its /mnt/ top if it has one.
disks() {
  df -B1 --output=target,source,size,used,avail -x tmpfs -x devtmpfs -x efivarfs -x overlay -x nfs4 | tail -n +2 |
    jq -Rn '[inputs | [splits(" +")] | {target: .[0], source: .[1], size: (.[2] | tonumber),
      used: (.[3] | tonumber), avail: (.[4] | tonumber)}]
      | sort_by([(.target | startswith("/mnt/") | not), (.target | length)]) | group_by(.source) | map(.[0])'
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
  jq -n --arg snaps "$(list "${SNAPSHOTS:-}")" --arg copies "$(list "${COPIES:-}")" \
    --arg taken "$(awk '$1 == "subvolume" {print $2}' "${BTRBK_CONF:-/dev/null}" 2> /dev/null | sort -u)" \
    --argjson drive "$(mountpoint -q "${COPIES_MOUNT:-${COPIES:-/nonexistent}}" && echo true || echo false)" \
    '{drive: $drive, snapshots: ($snaps | split("\n") | map(select(. != ""))),
      copies: ($copies | split("\n") | map(select(. != ""))),
      taken: ($taken | split("\n") | map(select(. != "")))}'
}

units() { for u in $WATCH_UNITS; do unit "$u"; done | jq -s .; }

# Each site's certificate as it is served, and each root on disk.
certs() {
  {
    for entry in $CERTS; do
      name=${entry%%=*} address=${entry#*=}
      dates=$(timeout 10 openssl s_client -connect "$address" -servername "$name" < /dev/null 2> /dev/null |
        openssl x509 -noout -startdate -enddate -issuer 2> /dev/null)
      # The site itself, at the same address: its HTTP answer and how long it took.
      to=()
      [ "${address%:*}" = "$name" ] || to=(--resolve "$name:${address##*:}:${address%:*}")
      read -r code took < <(curl -sk -o /dev/null --max-time 10 -w '%{http_code} %{time_total}' \
        "${to[@]}" "https://$name:${address##*:}/" || echo "000 0")
      cert_json "$name" "$dates" | jq --arg code "$code" --arg took "$took" \
        '. + {code: ($code | tonumber), took: ($took | tonumber)}'
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
