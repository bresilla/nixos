#!/usr/bin/env bash

size_to_mib() {
  local value="$1"
  local base_mib="${2:-0}"
  awk -v value="$value" -v base="$base_mib" '
    function ceil(n) { return int(n) == n ? n : int(n) + 1 }
    BEGIN {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^[0-9.]+%$/) {
        sub(/%$/, "", value)
        print ceil(base * value / 100)
        exit
      }

      number = value
      unit = value
      sub(/[^0-9.].*$/, "", number)
      sub(/^[0-9.]+[[:space:]]*/, "", unit)
      unit_l = tolower(unit)

      if (unit_l == "" || unit_l == "m" || unit_l == "mb" || unit_l == "mib") {
        print ceil(number)
      } else if (unit_l == "g" || unit_l == "gb" || unit_l == "gib") {
        print ceil(number * 1024)
      } else if (unit_l == "t" || unit_l == "tb" || unit_l == "tib") {
        print ceil(number * 1024 * 1024)
      } else if (unit_l == "k" || unit_l == "kb" || unit_l == "kib") {
        print ceil(number / 1024)
      } else {
        exit 2
      }
    }
  '
}

bytes_to_mib() {
  awk -v bytes="$1" 'BEGIN { print int(bytes / 1048576) }'
}

format_mib() {
  awk -v mib="$1" '
    BEGIN {
      if (mib < 0) {
        sign = "-"
        mib = -mib
      }
      if (mib >= 1048576) {
        printf "%s%.1fT", sign, mib / 1048576
      } else if (mib >= 1024) {
        printf "%s%.1fG", sign, mib / 1024
      } else {
        printf "%s%dM", sign, mib
      }
    }
  '
}

render_capacity_graph() {
  local title="$1"
  local total_mib="$2"
  local entries_file="$3"
  local width="${4:-72}"
  local bar_width used_mib free_mib over_mib label size_mib color cells line

  [[ "$width" -lt 40 ]] && width=40
  bar_width=$((width - 18))
  [[ "$bar_width" -lt 24 ]] && bar_width=24
  [[ "$bar_width" -gt 96 ]] && bar_width=96

  used_mib="$(awk -F '|' '{ sum += $2 } END { print int(sum) }' "$entries_file")"
  free_mib=$((total_mib - used_mib))
  over_mib=0
  if [[ "$free_mib" -lt 0 ]]; then
    over_mib=$((-free_mib))
    free_mib=0
  fi

  printf '%s\n' "$title"
  printf '  total: %s  used: %s  free: %s' \
    "$(format_mib "$total_mib")" \
    "$(format_mib "$used_mib")" \
    "$(format_mib "$free_mib")"
  if [[ "$over_mib" -gt 0 ]]; then
    printf '  over: %s' "$(format_mib "$over_mib")"
  fi
  printf '\n'

  printf '  ['
  while IFS='|' read -r label size_mib color; do
    [[ -n "$label" ]] || continue
    if [[ "$total_mib" -gt 0 ]]; then
      cells=$((size_mib * bar_width / total_mib))
    else
      cells=0
    fi
    [[ "$size_mib" -gt 0 && "$cells" -eq 0 ]] && cells=1
    line="$(printf '%*s' "$cells" '')"
    printf '\033[48;5;%sm%s\033[0m' "$color" "$line"
  done < "$entries_file"

  if [[ "$free_mib" -gt 0 && "$total_mib" -gt 0 ]]; then
    cells=$((free_mib * bar_width / total_mib))
    [[ "$cells" -eq 0 ]] && cells=1
    line="$(printf '%*s' "$cells" '')"
    printf '\033[48;5;238m%s\033[0m' "$line"
  fi
  printf ']\n'

  while IFS='|' read -r label size_mib color; do
    [[ -n "$label" ]] || continue
    printf '  \033[38;5;%sm%s\033[0m %s\n' "$color" "$label" "$(format_mib "$size_mib")"
  done < "$entries_file"
  if [[ "$free_mib" -gt 0 ]]; then
    printf '  \033[38;5;238mfree\033[0m %s\n' "$(format_mib "$free_mib")"
  fi

  [[ "$over_mib" -eq 0 ]]
}
