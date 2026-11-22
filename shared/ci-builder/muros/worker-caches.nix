{ pkgs, limitBytes, maxAgeSeconds }:
pkgs.writeShellApplication {
  name = "muros-worker-caches";
  runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.jq ];
  text = ''
    root=''${MUROS_WORKER_CACHES:-/var/cache/private/muros}
    report=''${MUROS_WORKER_CACHES_REPORT:-/var/lib/muros-worker-caches/report.json}
    limit=''${1:-${toString limitBytes}}
    age=''${2:-${toString maxAgeSeconds}}
    now=$(date +%s)
    evicted=0
    evicted_bytes=0
    kept=()
    sizes=()
    total=0

    # Entries are ROOT/SCOPE/KEY, oldest use first; dot names are interrupted saves.
    if [[ -d $root ]]; then
      while read -r stamp path; do
        stamp=''${stamp%.*}
        size=$(du -sb -- "$path" | cut -f1)
        if [[ ''${path##*/} == .* ]]; then
          if (( now - stamp > 86400 )); then
            rm -rf -- "$path"
          fi
        elif (( now - stamp > age )); then
          rm -rf -- "$path"
          evicted=$((evicted + 1))
          evicted_bytes=$((evicted_bytes + size))
        else
          kept+=("$path")
          sizes+=("$size")
          total=$((total + size))
        fi
      done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -printf '%T@ %p\n' | sort -n)
    fi

    entries=''${#kept[@]}
    for index in "''${!kept[@]}"; do
      if (( total <= limit )); then
        break
      fi
      rm -rf -- "''${kept[index]}"
      total=$((total - sizes[index]))
      entries=$((entries - 1))
      evicted=$((evicted + 1))
      evicted_bytes=$((evicted_bytes + sizes[index]))
    done

    mkdir -p "''${report%/*}"
    jq -n --argjson checked_at "$now" --argjson bytes "$total" --argjson entries "$entries" \
      --argjson limit_bytes "$limit" --argjson max_age_seconds "$age" \
      --argjson evicted_entries "$evicted" --argjson evicted_bytes "$evicted_bytes" \
      '{schema_version: 1, checked_at: $checked_at, bytes: $bytes, entries: $entries,
        limit_bytes: $limit_bytes, max_age_seconds: $max_age_seconds,
        evicted_entries: $evicted_entries, evicted_bytes: $evicted_bytes}' > "$report.tmp"
    mv -- "$report.tmp" "$report"
  '';
}
