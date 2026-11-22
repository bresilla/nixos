{ pkgs, profile }:
pkgs.writeShellApplication {
  name = "muros-worker-inspection";
  runtimeInputs = [ pkgs.coreutils pkgs.gawk pkgs.jq ];
  text = ''
    export LC_ALL=C
    unset OMP_NUM_THREADS OMP_THREAD_LIMIT
    memory='null null'
    if [[ -r /proc/meminfo ]]; then
      memory=$(awk '
        /^MemTotal:/ { total = $2 * 1024 }
        /^MemAvailable:/ { available = $2 * 1024 }
        END {
          if (total) printf "%.0f ", total; else printf "null ";
          if (available != "") printf "%.0f\n", available; else print "null";
        }' /proc/meminfo)
    fi
    read -r memory_total memory_available <<< "$memory"
    disk=$(df -B1 --output=size,avail -- ${builtins.storeDir} | tail -n 1)
    read -r store_total store_available <<< "$disk"
    if (( store_available < 0 )); then store_available=0; fi
    caches=null
    if [[ -r /var/lib/muros-worker-caches/report.json ]]; then
      caches=$(jq -c 'if type == "object" then . else null end' /var/lib/muros-worker-caches/report.json 2>/dev/null || echo null)
    fi
    jq -n \
      --argjson profile ${pkgs.lib.escapeShellArg (builtins.toJSON profile)} \
      --arg kernel_os "$(uname -s)" --arg kernel_machine "$(uname -m)" \
      --argjson processors_total "$(nproc --all)" \
      --argjson processors_available "$(nproc)" \
      --argjson memory_total "$memory_total" --argjson memory_available "$memory_available" \
      --argjson store_total "$store_total" --argjson store_available "$store_available" \
      --argjson caches "$caches" \
      '{profile: $profile, inventory: {
        schema_version: 1, kernel_os: $kernel_os, kernel_machine: $kernel_machine,
        processors_total: $processors_total, processors_available: $processors_available,
        memory_total_bytes: $memory_total, memory_available_bytes: $memory_available,
        store_total_bytes: $store_total, store_available_bytes: $store_available
      }} + (if $caches == null then {} else {caches: $caches} end)'
  '';
}
