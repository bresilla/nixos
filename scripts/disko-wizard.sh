#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/scripts/disko-math.sh"
scope="${1:-}"
target="${2:-}"
BACK_TOKEN="__NIXOS_INSTALL_BACK__"
BACK_EXIT=42

trap 'echo >&2; exit 130' INT

find_gum() {
  if [[ -n "${GUM_BIN:-}" && -x "${GUM_BIN:-}" ]]; then
    printf '%s\n' "$GUM_BIN"
    return 0
  fi

  command -v gum 2>/dev/null && return 0

  if [[ -x /tmp/nixos-install-tools/gum ]]; then
    printf '%s\n' /tmp/nixos-install-tools/gum
    return 0
  fi

  return 1
}

download_gum() {
  local os arch asset_pattern api url tmp gum_bin
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os:$arch" in
    Linux:x86_64) asset_pattern='Linux_x86_64.tar.gz' ;;
    Linux:aarch64 | Linux:arm64) asset_pattern='Linux_arm64.tar.gz' ;;
    *) die "automatic gum download is not supported on $os/$arch; install gum manually" ;;
  esac

  command -v curl >/dev/null || die "curl is required to download gum"
  command -v tar >/dev/null || die "tar is required to unpack gum"

  api="$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest)"
  url="$(
    printf '%s\n' "$api" \
      | sed -nE 's/.*"browser_download_url": "([^"]*'"$asset_pattern"')".*/\1/p' \
      | head -n 1
  )"

  [[ -n "$url" ]] || die "could not find gum release asset matching $asset_pattern"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL "$url" -o "$tmp/gum.tar.gz"
  tar -xzf "$tmp/gum.tar.gz" -C "$tmp"

  gum_bin="$(find "$tmp" -type f -name gum -perm -111 | head -n 1)"
  [[ -n "$gum_bin" ]] || die "gum archive did not contain an executable gum binary"

  install -d -m 0755 /tmp/nixos-install-tools
  install -m 0755 "$gum_bin" /tmp/nixos-install-tools/gum
  printf '%s\n' /tmp/nixos-install-tools/gum
}

ensure_gum() {
  find_gum || download_gum
}

ui_width() {
  local cols
  cols=""
  if [[ -r /dev/tty ]] && command -v stty >/dev/null; then
    cols="$(stty size 2>/dev/null < /dev/tty | awk '{ print $2 }')"
  fi
  if [[ -z "$cols" ]]; then
    cols="${COLUMNS:-}"
  fi
  if [[ -z "$cols" ]] && command -v tput >/dev/null; then
    cols="$(tput cols 2>/dev/null || true)"
  fi
  cols="${cols:-80}"
  [[ "$cols" -lt 52 ]] && cols=52
  [[ "$cols" -gt 54 ]] && cols=$((cols - 2))
  printf '%s\n' "$cols"
}

ui_title() {
  local title="$1"
  local prev="${2:-}"
  local next="${3:-}"
  local width inner line blank text_width left right row title_pos title_len right_pos max_left_len max_right_len before after
  width="$(ui_width)"
  inner=$((width - 2))
  text_width=$((inner - 2))
  line="$(ui_repeat_char "$inner" "─")"
  blank="$(printf '%*s' "$inner" '')"
  left="Esc: ${prev:-back}"
  right="Next: ${next:-continue}"
  title_len="${#title}"
  if [[ "$title_len" -gt "$text_width" ]]; then
    title="${title:0:text_width}"
    title_len="${#title}"
  fi
  title_pos=$(((text_width - title_len) / 2))

  max_left_len=$((title_pos - 1))
  [[ "$max_left_len" -lt 0 ]] && max_left_len=0
  if [[ "${#left}" -gt "$max_left_len" ]]; then
    left="${left:0:max_left_len}"
  fi

  max_right_len=$((text_width - title_pos - title_len - 1))
  [[ "$max_right_len" -lt 0 ]] && max_right_len=0
  if [[ "${#right}" -gt "$max_right_len" ]]; then
    right="${right:0:max_right_len}"
  fi
  right_pos=$((text_width - ${#right}))
  row="$(printf '%*s' "$text_width" '')"
  row="${left}${row:${#left}}"
  row="${row:0:right_pos}${right}${row:right_pos+${#right}}"
  before="${row:0:title_pos}"
  after="${row:title_pos+title_len}"

  printf '\n\033[96m╭%s╮\033[0m\n' "$line"
  printf '\033[96m│%s│\033[0m\n' "$blank"
  printf '\033[96m│\033[0m \033[90m%s\033[0m\033[97;1m%s\033[0m\033[90m%s\033[0m \033[96m│\033[0m\n' "$before" "$title" "$after"
  printf '\033[96m│%s│\033[0m\n' "$blank"
  printf '\033[96m╰%s╯\033[0m\n\n' "$line"
}

ui_repeat_char() {
  local count="$1"
  local char="$2"
  local out=""
  local i
  for ((i = 0; i < count; i++)); do
    out+="$char"
  done
  printf '%s\n' "$out"
}

ui_clear() {
  if [[ -w /dev/tty ]]; then
    printf '\033[H\033[2J\033[3J' > /dev/tty
  else
    printf '\033[H\033[2J\033[3J'
  fi
}

ui_screen() {
  local section="${1:-}"
  local prev="${2:-}"
  local next="${3:-}"
  ui_clear
  {
    ui_title "Disk layout" "$prev" "$next"
    ui_note "Build a Disko file from your answers. The installer always uses the generated laptop/server system config."
    [[ -n "$section" ]] && ui_section "$section"
  } > /dev/tty
}

ui_section() {
  printf '\n\033[96;1m%s\033[0m\n\n' "$1"
}

ui_note() {
  printf '\033[90m%s\033[0m\n\n' "$1"
}

ui_success() {
  printf '\033[92;1m%s\033[0m\n' "$1"
}

ui_info() {
  printf '\033[93m%s\033[0m\n' "$1"
}

ui_warn() {
  printf '\033[93;1m%s\033[0m\n' "$1"
}

ui_choose() {
  local header="$1"
  local out rc tmp_out
  shift
  tmp_out="$(mktemp)"
  set +e
  "$gum" choose \
    --header "$header" \
    --height 10 \
    --cursor "> " \
    --cursor-prefix "> " \
    --selected-prefix "[x] " \
    --unselected-prefix "[ ] " \
    --header.foreground 14 \
    --cursor.foreground 0 \
    --cursor.background 1 \
    --selected.foreground 0 \
    --selected.background 1 \
    --item.foreground 15 \
    --padding "1 2" \
    "$@" > "$tmp_out"
  rc=$?
  set -e
  [[ "$rc" -eq 130 ]] && exit 130
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp_out"
    printf '%s\n' "$BACK_TOKEN"
    return 0
  fi
  out="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  printf '%s\n' "$out"
}

ui_choose_multi() {
  local header="$1"
  local out rc tmp_out
  shift
  tmp_out="$(mktemp)"
  set +e
  "$gum" choose \
    --no-limit \
    --header "$header" \
    --height 12 \
    --cursor "> " \
    --cursor-prefix "[ ] " \
    --selected-prefix "[x] " \
    --unselected-prefix "[ ] " \
    --header.foreground 14 \
    --cursor.foreground 0 \
    --cursor.background 1 \
    --selected.foreground 0 \
    --selected.background 1 \
    --item.foreground 15 \
    --padding "1 2" \
    "$@" > "$tmp_out"
  rc=$?
  set -e
  [[ "$rc" -eq 130 ]] && exit 130
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp_out"
    printf '%s\n' "$BACK_TOKEN"
    return 0
  fi
  out="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  printf '%s\n' "$out"
}

ui_input() {
  local prompt="$1"
  local default="$2"
  local out rc tmp_out
  tmp_out="$(mktemp)"
  set +e
  "$gum" input \
    --prompt "$prompt " \
    --value "$default" \
    --width 72 \
    --prompt.foreground 14 \
    --placeholder.foreground 8 \
    --cursor.foreground 13 \
    --padding "1 2" > "$tmp_out"
  rc=$?
  set -e
  [[ "$rc" -eq 130 ]] && exit 130
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp_out"
    printf '%s\n' "$BACK_TOKEN"
    return 0
  fi
  out="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  printf '%s\n' "$out"
}

ui_confirm() {
  local rc
  set +e
  "$gum" confirm "$1" \
    --affirmative "yes" \
    --negative "no" \
    --prompt.foreground 14 \
    --selected.foreground 0 \
    --selected.background 10 \
    --unselected.foreground 15 \
    --unselected.background 0 \
    --padding "1 2"
  rc=$?
  set -e
  [[ "$rc" -eq 130 ]] && exit 130
  [[ "$rc" -ne 0 ]] && exit "$BACK_EXIT"
  return 0
}

ssh_install_base_opts() {
  printf '%s\n' \
    -F /dev/null \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no
}

ssh_key_auth_ok() {
  local ssh_target="$1"
  local -a ssh_opts
  mapfile -t ssh_opts < <(ssh_install_base_opts)
  ssh "${ssh_opts[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    "$ssh_target" true >/dev/null 2>&1
}

choose_ssh_public_key() {
  local keys=()
  local key selected

  if [[ -n "${NIXOS_INSTALL_SSH_PUBKEY:-}" ]]; then
    [[ -f "$NIXOS_INSTALL_SSH_PUBKEY" ]] || die "NIXOS_INSTALL_SSH_PUBKEY does not exist: $NIXOS_INSTALL_SSH_PUBKEY"
    printf '%s\n' "$NIXOS_INSTALL_SSH_PUBKEY"
    return 0
  fi

  for key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME"/.ssh/*.pub; do
    [[ -f "$key" ]] || continue
    [[ "$(basename "$key")" == known_hosts* ]] && continue
    keys+=("$key")
  done

  [[ "${#keys[@]}" -gt 0 ]] || die "no SSH public key found in $HOME/.ssh; create one with ssh-keygen first"

  if [[ "${#keys[@]}" -eq 1 ]]; then
    printf '%s\n' "${keys[0]}"
    return 0
  fi

  selected="$(ui_choose "public key to install on target" "${keys[@]}")"
  go_back_if_requested "$selected"
  printf '%s\n' "$selected"
}

ensure_remote_ssh_access() {
  local ssh_target="$1"
  local pubkey

  command -v ssh >/dev/null || die "ssh is required for remote disk scanning"
  if ssh_key_auth_ok "$ssh_target"; then
    return 0
  fi

  command -v ssh-copy-id >/dev/null || die "ssh key auth failed and ssh-copy-id is not installed"
  pubkey="$(choose_ssh_public_key)"

  ui_warn "SSH key auth failed for $ssh_target."
  ui_info "I can run ssh-copy-id now. It will ask for the target user's password, then install:"
  ui_info "  $pubkey"
  confirm "Install this SSH public key on $ssh_target?"

  ssh-copy-id \
    -F /dev/null \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    -i "$pubkey" \
    "$ssh_target" < /dev/tty

  ssh_key_auth_ok "$ssh_target" || die "SSH key auth still failed after ssh-copy-id"
  ui_success "ssh key auth: ok ($ssh_target)"
}

go_back_if_requested() {
  [[ "${1:-}" == "$BACK_TOKEN" ]] && exit "$BACK_EXIT"
  return 0
}

generated_disko_file() {
  local generated_dir="$repo_dir/generated"
  install -d -m 0755 "$generated_dir"
  printf '%s\n' "$generated_dir/disko.nix"
}

generated_summary_file() {
  local generated_dir="$repo_dir/generated"
  install -d -m 0755 "$generated_dir"
  printf '%s\n' "$generated_dir/install-summary.txt"
}

write_config_summary() {
  local out_file="$1"
  local summary_file disk lv_name vg part_name part_size luks_name total_mib used_mib free_mib lv_mib
  summary_file="$(generated_summary_file)"

  {
    echo "Disk layout"
    if [[ -n "$target" ]]; then
      echo "  disk source: remote $target"
    else
      echo "  disk source: local machine"
    fi
    echo "  source: configured interactively"
    echo "  generated disko: $out_file"
    echo
    echo "Selected disks"
    for disk in "${selected_disks[@]}"; do
      echo "  $disk"
    done
    echo
    echo "Boot"
    echo "  ESP disk: $esp_disk"
    echo "  ESP size: $esp_size"
    echo
    echo "Storage"
    echo "  layer: $storage_mode"
    echo "  filesystem: $fs_type"
    echo "  encryption: $luks_mode"

    if [[ "$storage_mode" == "LVM" ]]; then
      echo
      echo "Physical volumes"
      for disk in "${selected_disks[@]}"; do
        part_name="${disk_part_name[$disk]}"
        part_size="${disk_part_size[$disk]}"
        printf '  %s -> %s (%s) -> VG %s' "$disk" "$part_name" "$part_size" "${disk_vg[$disk]}"
        if [[ "$luks_enabled" == "yes" ]]; then
          printf ' through LUKS %s' "${disk_luks_name[$disk]}"
        fi
        printf '\n'
      done

      echo
      echo "Logical volumes"
      for vg in "${vg_names[@]}"; do
        echo "  VG $vg"
        total_mib=0
        used_mib=0
        for disk in "${selected_disks[@]}"; do
          [[ "${disk_vg[$disk]}" == "$vg" ]] || continue
          total_mib=$((total_mib + $(size_to_mib "${disk_part_size[$disk]}" "${disk_usable_mib[$disk]}")))
        done
        for lv_name in "${lv_names[@]}"; do
          [[ "${lv_vg[$lv_name]}" == "$vg" ]] || continue
          lv_mib="$(size_to_mib "${lv_size[$lv_name]}" "$total_mib")"
          used_mib=$((used_mib + lv_mib))
          if [[ "${lv_kind[$lv_name]}" == "swap" ]]; then
            echo "    $lv_name: swap, size ${lv_size[$lv_name]}"
          else
            echo "    $lv_name: ${lv_mount[$lv_name]}, size ${lv_size[$lv_name]}"
          fi
        done
        free_mib=$((total_mib - used_mib))
        echo "    capacity: $(format_mib "$total_mib") total, $(format_mib "$used_mib") used, $(format_mib "$free_mib") free"
      done
    else
      echo
      echo "Partitions"
      for lv_name in "${lv_names[@]}"; do
        part_name="${plain_part_name[$lv_name]}"
        part_size="${plain_part_size[$lv_name]}"
        disk="${plain_part_disk[$lv_name]}"
        if [[ "${lv_kind[$lv_name]}" == "swap" ]]; then
          printf '  %s on %s: swap, size %s' "$part_name" "$disk" "$part_size"
        else
          printf '  %s on %s: %s, size %s' "$part_name" "$disk" "${lv_mount[$lv_name]}" "$part_size"
        fi
        if [[ "$luks_enabled" == "yes" ]]; then
          luks_name="${plain_luks_name[$lv_name]:-}"
          printf ' through LUKS %s' "$luks_name"
        fi
        printf '\n'
      done

      echo
      echo "Disk capacity"
      for disk in "${selected_disks[@]}"; do
        used_mib=0
        for lv_name in "${lv_names[@]}"; do
          [[ "${plain_part_disk[$lv_name]}" == "$disk" ]] || continue
          used_mib=$((used_mib + $(size_to_mib "${plain_part_size[$lv_name]}" "${disk_usable_mib[$disk]}")))
        done
        free_mib=$((disk_usable_mib[$disk] - used_mib))
        echo "  $disk: $(format_mib "${disk_usable_mib[$disk]}") total, $(format_mib "$used_mib") used, $(format_mib "$free_mib") free"
      done
    fi

    if [[ "$fs_type" == "btrfs" && "${#doc_subvolumes[@]}" -gt 0 ]]; then
      echo
      echo "Doc subvolumes"
      for lv_name in "${doc_subvolumes[@]}"; do
        [[ -n "$lv_name" ]] || continue
        echo "  /doc/$lv_name"
      done
    fi
  } > "$summary_file"
}

input_default() {
  local prompt="$1"
  local default="$2"
  local keep_screen="${3:-}"
  local value
  if [[ "$keep_screen" != "keep-screen" ]]; then
    ui_screen "${prompt%: }" "previous" "next"
  fi
  value="$(ui_input "$prompt" "$default")"
  go_back_if_requested "$value"
  printf '%s\n' "$value"
}

confirm() {
  local prompt="$1"
  ui_confirm "$prompt"
}

disk_options() {
  if [[ -n "$target" ]]; then
    local -a ssh_opts
    command -v ssh >/dev/null || die "ssh is required for remote disk scanning"
    mapfile -t ssh_opts < <(ssh_install_base_opts)
    ssh "${ssh_opts[@]}" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      "$target" \
      "lsblk -dnpo NAME,SIZE,TYPE,MODEL 2>/dev/null" \
      | awk '$3 == "disk" { $3 = ""; sub(/[[:space:]]+$/, ""); print }'
    return
  fi

  lsblk -dnpo NAME,SIZE,TYPE,MODEL 2>/dev/null \
    | awk '$3 == "disk" { $3 = ""; sub(/[[:space:]]+$/, ""); print }'
}

disk_name_from_option() {
  awk '{ print $1 }'
}

disk_key() {
  local disk="$1"
  basename "$disk" | tr -c 'A-Za-z0-9_' '_'
}

lv_name_for_mount() {
  case "$1" in
    /) printf '%s\n' root ;;
    /home) printf '%s\n' home ;;
    /doc) printf '%s\n' docs ;;
    /nix) printf '%s\n' nix ;;
    /pkg) printf '%s\n' pkg ;;
    swap) printf '%s\n' swap ;;
    *) printf '%s\n' "$1" | sed 's#^/##; s#[^A-Za-z0-9_]#_#g' ;;
  esac
}

default_size_for_mount() {
  case "$1" in
    /) printf '%s\n' 128G ;;
    /home) printf '%s\n' 256G ;;
    /doc) printf '%s\n' 256G ;;
    /nix) printf '%s\n' 128G ;;
    /pkg) printf '%s\n' 128G ;;
    swap) printf '%s\n' 64G ;;
    *) printf '%s\n' 64G ;;
  esac
}

emit_mount_options() {
  cat <<'EOF'
                  mountOptions = [
                    "noatime"
                    "compress=zstd:3"
                    "ssd"
                    "space_cache=v2"
                  ];
EOF
}

emit_btrfs_lv() {
  local name="$1"
  local size="$2"
  local mountpoint="$3"

  cat <<EOF
          $name = {
            size = "$size";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" "-L" "$name" ];
              subvolumes = {
                "/@$name" = {
                  mountpoint = "$mountpoint";
EOF
  emit_mount_options
  cat <<'EOF'
                };
              };
            };
          };
EOF
}

emit_doc_lv() {
  local name="$1"
  local size="$2"
  local subvol

  cat <<EOF
          $name = {
            size = "$size";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" "-L" "$name" ];
              subvolumes = {
EOF
  for subvol in "${doc_subvolumes[@]}"; do
    [[ -n "$subvol" ]] || continue
    cat <<EOF
                "/$subvol" = {
                  mountpoint = "/doc/$subvol";
EOF
    emit_mount_options
    cat <<'EOF'
                };
EOF
  done
  cat <<'EOF'
              };
            };
          };
EOF
}

emit_ext4_lv() {
  local name="$1"
  local size="$2"
  local mountpoint="$3"

  cat <<EOF
          $name = {
            size = "$size";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "$mountpoint";
            };
          };
EOF
}

emit_fs_lv() {
  local name="$1"
  local size="$2"
  local mountpoint="$3"
  local fs="$4"

  if [[ "$fs" == "btrfs" ]]; then
    if [[ "$mountpoint" == "/doc" ]]; then
      emit_doc_lv "$name" "$size"
    else
      emit_btrfs_lv "$name" "$size" "$mountpoint"
    fi
  else
    emit_ext4_lv "$name" "$size" "$mountpoint"
  fi
}

emit_swap_lv() {
  local name="$1"
  local size="$2"

  cat <<EOF
          $name = {
            size = "$size";
            content = {
              type = "swap";
              extraArgs = [ "-L" "$name" ];
              resumeDevice = true;
            };
          };
EOF
}

emit_plain_fs_content() {
  local name="$1"
  local mountpoint="$2"
  local fs="$3"
  local indent="$4"

  if [[ "$fs" == "btrfs" ]]; then
    if [[ "$mountpoint" == "/doc" ]]; then
      cat <<EOF
${indent}content = {
${indent}  type = "btrfs";
${indent}  extraArgs = [ "-f" "-L" "$name" ];
${indent}  subvolumes = {
EOF
      for subvol in "${doc_subvolumes[@]}"; do
        [[ -n "$subvol" ]] || continue
        cat <<EOF
${indent}    "/$subvol" = {
${indent}      mountpoint = "/doc/$subvol";
${indent}      mountOptions = [
${indent}        "noatime"
${indent}        "compress=zstd:3"
${indent}        "ssd"
${indent}        "space_cache=v2"
${indent}      ];
${indent}    };
EOF
      done
      cat <<EOF
${indent}  };
${indent}};
EOF
    else
      cat <<EOF
${indent}content = {
${indent}  type = "btrfs";
${indent}  extraArgs = [ "-f" "-L" "$name" ];
${indent}  subvolumes = {
${indent}    "/@$name" = {
${indent}      mountpoint = "$mountpoint";
${indent}      mountOptions = [
${indent}        "noatime"
${indent}        "compress=zstd:3"
${indent}        "ssd"
${indent}        "space_cache=v2"
${indent}      ];
${indent}    };
${indent}  };
${indent}};
EOF
    fi
  else
    cat <<EOF
${indent}content = {
${indent}  type = "filesystem";
${indent}  format = "ext4";
${indent}  mountpoint = "$mountpoint";
${indent}};
EOF
  fi
}

emit_plain_partition_content() {
  local name="$1"
  local kind="$2"
  local mountpoint="$3"
  local fs="$4"
  local luks="$5"
  local luks_name="$6"
  local indent="              "

  if [[ "$luks" == "yes" ]]; then
    cat <<EOF
              content = {
                type = "luks";
                name = "$luks_name";
                settings.allowDiscards = true;
EOF
    if [[ "$kind" == "swap" ]]; then
      cat <<EOF
                content = {
                  type = "swap";
                  extraArgs = [ "-L" "$name" ];
                  resumeDevice = true;
                };
EOF
    else
      emit_plain_fs_content "$name" "$mountpoint" "$fs" "                "
    fi
    cat <<'EOF'
              };
EOF
  elif [[ "$kind" == "swap" ]]; then
    cat <<EOF
              content = {
                type = "swap";
                extraArgs = [ "-L" "$name" ];
                resumeDevice = true;
              };
EOF
  else
    emit_plain_fs_content "$name" "$mountpoint" "$fs" "$indent"
  fi
}

emit_partition_size() {
  local value="$1"
  local base_mib="$2"
  local indent="$3"
  local size

  if [[ "$value" =~ ^[0-9]+([.][0-9]+)?%$ && "$value" != "100%" ]]; then
    size="$(size_to_mib "$value" "$base_mib")"
    printf '%ssize = "%sM";\n' "$indent" "$size"
  else
    printf '%ssize = "%s";\n' "$indent" "$value"
  fi
}

gum="$(ensure_gum)"

if [[ -z "$scope" ]]; then
  ui_screen "Target" "installer target" "disk source"
  scope="$(ui_choose "where should disks be inspected?" "LOCAL" "REMOTE")"
  go_back_if_requested "$scope"
fi
[[ "$scope" == "LOCAL" || "$scope" == "REMOTE" ]] || die "scope must be LOCAL or REMOTE"

if [[ "$scope" == "REMOTE" && -z "$target" ]]; then
  ui_screen "Remote Target" "target" "disk source"
  target="$(ui_input "ssh target:" "nixos@192.168.100.163")"
  go_back_if_requested "$target"
  [[ -n "$target" ]] || die "ssh target is required"
fi

if [[ -n "$target" ]]; then
  ui_screen "Disk Source" "target" "install disks"
  ui_info "remote: $target"
  ensure_remote_ssh_access "$target"
else
  ui_screen "Disk Source" "target" "install disks"
  ui_info "local machine"
fi

available_disks="$(disk_options)"
[[ -n "$available_disks" ]] || die "no disks found with lsblk"

ui_screen "Install Disks" "disk source" "selected disks"
selected_disk_options="$(
  printf '%s\n' "$available_disks" \
    | ui_choose_multi "select install disk(s) - space selects, enter confirms"
)"
go_back_if_requested "$selected_disk_options"
[[ -n "$selected_disk_options" ]] || die "no disks selected"

mapfile -t selected_disks < <(printf '%s\n' "$selected_disk_options" | disk_name_from_option)
[[ "${#selected_disks[@]}" -gt 0 ]] || die "no disks selected"

ui_screen "Selected Disks" "install disks" "storage layer"
printf '  %s\n' "${selected_disks[@]}"
confirm "Generate a Disko config for these disks? This only writes Nix; it does not format now." \
  || die "cancelled"

esp_disk="${selected_disks[0]}"
if [[ "${#selected_disks[@]}" -gt 1 ]]; then
  ui_screen "EFI System Partition" "selected disks" "storage layer"
  esp_disk="$(
    printf '%s\n' "${selected_disks[@]}" \
      | ui_choose "disk for EFI system partition"
  )"
  go_back_if_requested "$esp_disk"
fi

esp_size="1024MiB"

ui_screen "Storage Layer" "selected disks" "filesystem"
storage_mode="$(
  ui_choose "storage layer" \
    "LVM" \
    "plain partitions"
)"
go_back_if_requested "$storage_mode"
[[ -n "$storage_mode" ]] || die "storage layer is required"

ui_screen "Filesystem" "storage layer" "encryption"
fs_type="$(
  ui_choose "filesystem for normal volumes" \
    "btrfs" \
    "ext4"
)"
go_back_if_requested "$fs_type"
[[ -n "$fs_type" ]] || die "filesystem is required"

ui_screen "Encryption" "filesystem" "volumes"
luks_mode="$(
  ui_choose "encryption" \
    "no LUKS" \
    "LUKS"
)"
go_back_if_requested "$luks_mode"
[[ -n "$luks_mode" ]] || die "encryption choice is required"
luks_enabled="no"
[[ "$luks_mode" == "LUKS" ]] && luks_enabled="yes"

declare -A disk_vg
declare -A disk_part_name
declare -A disk_part_size
declare -A disk_luks_name
declare -A disk_total_mib
declare -A disk_usable_mib
declare -a vg_names

declare -a mounts
declare -a doc_subvolumes
doc_subvolumes=()

declare -A lv_size
declare -A lv_vg
declare -A lv_mount
declare -A lv_kind
declare -a lv_names

declare -A plain_part_name
declare -A plain_part_size
declare -A plain_part_disk
declare -A plain_luks_name

disk_size_bytes() {
  local disk="$1"
  local -a ssh_opts
  if [[ -n "$target" ]]; then
    mapfile -t ssh_opts < <(ssh_install_base_opts)
    ssh "${ssh_opts[@]}" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      "$target" \
      "lsblk -bdnro SIZE '$disk' 2>/dev/null | head -n 1 || true"
    return
  fi

  lsblk -bdnro SIZE "$disk" 2>/dev/null | head -n 1 || true
}

layout_color_for_index() {
  local index="$1"
  local colors=(39 42 45 81 111 141 177 213 220 208 203)
  printf '%s\n' "${colors[$((index % ${#colors[@]}))]}"
}

collect_disk_capacities() {
  local disk bytes total_mib esp_mib usable_mib
  esp_mib="$(size_to_mib "$esp_size")"

  for disk in "${selected_disks[@]}"; do
    bytes="$(disk_size_bytes "$disk")"
    [[ "$bytes" =~ ^[0-9]+$ ]] || die "could not read disk size for $disk"
    total_mib="$(bytes_to_mib "$bytes")"
    usable_mib="$total_mib"
    if [[ "$disk" == "$esp_disk" ]]; then
      usable_mib=$((usable_mib - esp_mib))
    fi
    [[ "$usable_mib" -gt 0 ]] || die "ESP size leaves no usable space on $disk"
    disk_total_mib["$disk"]="$total_mib"
    disk_usable_mib["$disk"]="$usable_mib"
  done
}

show_capacity_preview() {
  local tmp_dir vg disk lv_name part_mib lv_mib index color summary_width
  local -A vg_total_mib
  local -A vg_entries
  local -A disk_entries

  [[ "${#lv_names[@]}" -gt 0 ]] || return 0
  collect_disk_capacities
  tmp_dir="$(mktemp -d)"
  summary_width="$(ui_width)"

  ui_screen "Disk Usage Preview" "volume list" "next size"

  if [[ "$storage_mode" == "LVM" ]]; then
    for vg in "${vg_names[@]}"; do
      vg_total_mib["$vg"]=0
      vg_entries["$vg"]="$tmp_dir/vg_$vg.entries"
      : > "${vg_entries[$vg]}"
    done

    for disk in "${selected_disks[@]}"; do
      vg="${disk_vg[$disk]}"
      [[ -n "${vg:-}" ]] || continue
      [[ -n "${disk_part_size[$disk]:-}" ]] || continue
      part_mib="$(size_to_mib "${disk_part_size[$disk]}" "${disk_usable_mib[$disk]}")"
      [[ "$part_mib" -gt "${disk_usable_mib[$disk]}" ]] && part_mib="${disk_usable_mib[$disk]}"
      vg_total_mib["$vg"]=$((vg_total_mib[$vg] + part_mib))
    done

    index=0
    for lv_name in "${lv_names[@]}"; do
      [[ -n "${lv_vg[$lv_name]:-}" ]] || continue
      [[ -n "${lv_size[$lv_name]:-}" ]] || continue
      vg="${lv_vg[$lv_name]}"
      color="$(layout_color_for_index "$index")"
      lv_mib="$(size_to_mib "${lv_size[$lv_name]}" "${vg_total_mib[$vg]}")"
      if [[ "${lv_kind[$lv_name]}" == "swap" ]]; then
        printf '%s swap|%s|%s\n' "$lv_name" "$lv_mib" "$color" >> "${vg_entries[$vg]}"
      else
        printf '%s %s|%s|%s\n' "$lv_name" "${lv_mount[$lv_name]}" "$lv_mib" "$color" >> "${vg_entries[$vg]}"
      fi
      index=$((index + 1))
    done

    for vg in "${vg_names[@]}"; do
      render_capacity_graph "VG $vg" "${vg_total_mib[$vg]}" "${vg_entries[$vg]}" "$summary_width" || true
      printf '\n'
    done
  else
    for disk in "${selected_disks[@]}"; do
      disk_entries["$disk"]="$tmp_dir/disk_$(disk_key "$disk").entries"
      : > "${disk_entries[$disk]}"
    done

    index=0
    for lv_name in "${lv_names[@]}"; do
      [[ -n "${plain_part_disk[$lv_name]:-}" ]] || continue
      [[ -n "${plain_part_size[$lv_name]:-}" ]] || continue
      disk="${plain_part_disk[$lv_name]}"
      color="$(layout_color_for_index "$index")"
      lv_mib="$(size_to_mib "${plain_part_size[$lv_name]}" "${disk_usable_mib[$disk]}")"
      if [[ "${lv_kind[$lv_name]}" == "swap" ]]; then
        printf '%s swap|%s|%s\n' "$lv_name" "$lv_mib" "$color" >> "${disk_entries[$disk]}"
      else
        printf '%s %s|%s|%s\n' "$lv_name" "${lv_mount[$lv_name]}" "$lv_mib" "$color" >> "${disk_entries[$disk]}"
      fi
      index=$((index + 1))
    done

    for disk in "${selected_disks[@]}"; do
      render_capacity_graph "$disk" "${disk_usable_mib[$disk]}" "${disk_entries[$disk]}" "$summary_width" || true
      printf '\n'
    done
  fi

  rm -rf "$tmp_dir"
}

review_capacity_or_back() {
  local tmp_dir tmp_file ok vg disk lv_name part_mib vg_mib lv_mib index color summary_width
  local -A vg_total_mib
  local -A vg_entries
  local -A disk_entries

  collect_disk_capacities
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir:-}" "${tmp:-}"' EXIT
  ok=0
  summary_width="$(ui_width)"

  ui_screen "Capacity Review" "volume sizes" "write disko"

  if [[ "$storage_mode" == "LVM" ]]; then
    for vg in "${vg_names[@]}"; do
      vg_total_mib["$vg"]=0
      vg_entries["$vg"]="$tmp_dir/vg_$vg.entries"
      : > "${vg_entries[$vg]}"
    done

    for disk in "${selected_disks[@]}"; do
      vg="${disk_vg[$disk]}"
      part_mib="$(size_to_mib "${disk_part_size[$disk]}" "${disk_usable_mib[$disk]}")"
      if [[ "$part_mib" -gt "${disk_usable_mib[$disk]}" ]]; then
        part_mib="${disk_usable_mib[$disk]}"
      fi
      vg_total_mib["$vg"]=$((vg_total_mib[$vg] + part_mib))
    done

    index=0
    for lv_name in "${lv_names[@]}"; do
      vg="${lv_vg[$lv_name]}"
      color="$(layout_color_for_index "$index")"
      lv_mib="$(size_to_mib "${lv_size[$lv_name]}" "${vg_total_mib[$vg]}")"
      if [[ "${lv_kind[$lv_name]}" == "swap" ]]; then
        printf '%s|%s|%s\n' "$lv_name swap" "$lv_mib" "$color" >> "${vg_entries[$vg]}"
      else
        printf '%s %s|%s|%s\n' "$lv_name" "${lv_mount[$lv_name]}" "$lv_mib" "$color" >> "${vg_entries[$vg]}"
      fi
      index=$((index + 1))
    done

    for vg in "${vg_names[@]}"; do
      render_capacity_graph "VG $vg" "${vg_total_mib[$vg]}" "${vg_entries[$vg]}" "$summary_width" || ok=1
      printf '\n'
    done
  else
    for disk in "${selected_disks[@]}"; do
      disk_entries["$disk"]="$tmp_dir/disk_$(disk_key "$disk").entries"
      : > "${disk_entries[$disk]}"
    done

    index=0
    for lv_name in "${lv_names[@]}"; do
      disk="${plain_part_disk[$lv_name]}"
      color="$(layout_color_for_index "$index")"
      lv_mib="$(size_to_mib "${plain_part_size[$lv_name]}" "${disk_usable_mib[$disk]}")"
      if [[ "${lv_kind[$lv_name]}" == "swap" ]]; then
        printf '%s swap|%s|%s\n' "$lv_name" "$lv_mib" "$color" >> "${disk_entries[$disk]}"
      else
        printf '%s %s|%s|%s\n' "$lv_name" "${lv_mount[$lv_name]}" "$lv_mib" "$color" >> "${disk_entries[$disk]}"
      fi
      index=$((index + 1))
    done

    for disk in "${selected_disks[@]}"; do
      render_capacity_graph "$disk" "${disk_usable_mib[$disk]}" "${disk_entries[$disk]}" "$summary_width" || ok=1
      printf '\n'
    done
  fi

  if [[ "$ok" -ne 0 ]]; then
    ui_info "This layout is larger than the selected disk/VG capacity."
    confirm "Go back and fix the disk sizes?"
    exit "$BACK_EXIT"
  fi

  confirm "Use this capacity plan?"
  rm -rf "$tmp_dir"
  trap - EXIT
}

esp_size="$(input_default "ESP size: " "$esp_size")"

if [[ "$storage_mode" == "LVM" ]]; then
  pool_mode="one pooled VG"
  if [[ "${#selected_disks[@]}" -gt 1 ]]; then
    pool_mode="$(
      ui_choose "LVM mode" \
        "one pooled VG" \
        "one VG per disk"
    )"
    go_back_if_requested "$pool_mode"
  fi

  if [[ "$pool_mode" == "one pooled VG" ]]; then
    vg_name="$(input_default "VG name: " "pool")"
    vg_names=("$vg_name")
    for disk in "${selected_disks[@]}"; do
      disk_vg["$disk"]="$vg_name"
    done
  else
    for disk in "${selected_disks[@]}"; do
      default_vg="vg_$(disk_key "$disk")"
      vg_name="$(input_default "VG name for $disk: " "$default_vg")"
      disk_vg["$disk"]="$vg_name"
      vg_names+=("$vg_name")
    done
  fi

  for disk in "${selected_disks[@]}"; do
    default_part="lvm"
    if [[ "${#selected_disks[@]}" -gt 1 ]]; then
      default_part="lvm_$(disk_key "$disk")"
    fi
    disk_part_name["$disk"]="$(input_default "LVM partition name for $disk: " "$default_part")"
    disk_part_size["$disk"]="$(input_default "LVM partition size for $disk: " "100%")"
    if [[ "$luks_enabled" == "yes" ]]; then
      disk_luks_name["$disk"]="$(input_default "LUKS name for $disk: " "crypt_$(disk_key "$disk")")"
    fi
  done
fi

extra_mounts="$(
  ui_choose_multi "extra volumes beside / - space selects, enter confirms" \
    "/home" \
    "/doc" \
    "/nix" \
    "/pkg" \
    "swap" \
    "custom mount"
)"
go_back_if_requested "$extra_mounts"

mounts=("/")
if [[ -n "$extra_mounts" ]]; then
  while IFS= read -r mount; do
    [[ -n "$mount" ]] || continue
    if [[ "$mount" == "custom mount" ]]; then
      custom_mount="$(input_default "custom mountpoint: " "/srv")"
      mounts+=("$custom_mount")
    else
      mounts+=("$mount")
    fi
  done <<< "$extra_mounts"
fi

for mount in "${mounts[@]}"; do
  if [[ "$mount" == "/doc" && "$fs_type" == "btrfs" ]]; then
    doc_csv="$(input_default "doc subvolumes, comma separated: " "code,data,self,work")"
    IFS=',' read -r -a doc_subvolumes <<< "$doc_csv"
  fi
done

for mount in "${mounts[@]}"; do
  lv_name="$(lv_name_for_mount "$mount")"
  if [[ "$storage_mode" == "LVM" ]]; then
    lv_names+=("$lv_name")
    lv_mount["$lv_name"]="$mount"
    lv_kind["$lv_name"]="fs"
    [[ "$mount" == "swap" ]] && lv_kind["$lv_name"]="swap"

    if [[ "${#vg_names[@]}" -eq 1 ]]; then
      lv_vg["$lv_name"]="${vg_names[0]}"
    else
      lv_vg["$lv_name"]="$(
        printf '%s\n' "${vg_names[@]}" \
          | ui_choose "VG for $lv_name"
      )"
      go_back_if_requested "${lv_vg[$lv_name]}"
    fi

    lv_size["$lv_name"]="$(default_size_for_mount "$mount")"
    show_capacity_preview
    lv_size["$lv_name"]="$(input_default "$lv_name LV size: " "${lv_size[$lv_name]}" "keep-screen")"
  else
    lv_names+=("$lv_name")
    lv_mount["$lv_name"]="$mount"
    lv_kind["$lv_name"]="fs"
    [[ "$mount" == "swap" ]] && lv_kind["$lv_name"]="swap"
    plain_part_name["$lv_name"]="$(input_default "partition name for $lv_name: " "$lv_name")"
    if [[ "${#selected_disks[@]}" -eq 1 ]]; then
      plain_part_disk["$lv_name"]="${selected_disks[0]}"
    else
      plain_part_disk["$lv_name"]="$(
        printf '%s\n' "${selected_disks[@]}" \
          | ui_choose "disk for $lv_name"
      )"
      go_back_if_requested "${plain_part_disk[$lv_name]}"
    fi
    plain_part_size["$lv_name"]="$(default_size_for_mount "$mount")"
    show_capacity_preview
    plain_part_size["$lv_name"]="$(input_default "partition size for $lv_name: " "${plain_part_size[$lv_name]}" "keep-screen")"
    if [[ "$luks_enabled" == "yes" ]]; then
      plain_luks_name["$lv_name"]="$(input_default "LUKS name for $lv_name: " "crypt_$lv_name")"
    fi
  fi
done

review_capacity_or_back

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
  cat <<'EOF'
{ lib, ... }:

{
  disko.devices = lib.mkForce {
    disk = {
EOF

  for disk in "${selected_disks[@]}"; do
    key="$(disk_key "$disk")"
    cat <<EOF
      $key = {
        type = "disk";
        device = "$disk";
        content = {
          type = "gpt";
          partitions = {
EOF
    if [[ "$disk" == "$esp_disk" ]]; then
      cat <<EOF
            ESP = {
              priority = 1;
              name = "ESP";
              start = "1MiB";
              end = "$esp_size";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot/efi";
                mountOptions = [ "umask=0077" ];
              };
            };
EOF
    fi

    if [[ "$storage_mode" == "LVM" ]]; then
      vg="${disk_vg[$disk]}"
      part_name="${disk_part_name[$disk]}"
      part_size="${disk_part_size[$disk]}"
      if [[ "$luks_enabled" == "yes" ]]; then
        luks_name="${disk_luks_name[$disk]}"
        cat <<EOF
            $part_name = {
EOF
        emit_partition_size "$part_size" "${disk_usable_mib[$disk]}" "              "
        cat <<EOF
              content = {
                type = "luks";
                name = "$luks_name";
                settings.allowDiscards = true;
                content = {
                  type = "lvm_pv";
                  vg = "$vg";
                };
              };
            };
EOF
      else
        cat <<EOF
            $part_name = {
EOF
        emit_partition_size "$part_size" "${disk_usable_mib[$disk]}" "              "
        cat <<EOF
              content = {
                type = "lvm_pv";
                vg = "$vg";
              };
            };
EOF
      fi
    else
      for lv_name in "${lv_names[@]}"; do
        [[ "${plain_part_disk[$lv_name]}" == "$disk" ]] || continue
        part_name="${plain_part_name[$lv_name]}"
        part_size="${plain_part_size[$lv_name]}"
        luks_name="${plain_luks_name[$lv_name]:-}"
        cat <<EOF
            $part_name = {
EOF
        emit_partition_size "$part_size" "${disk_usable_mib[$disk]}" "              "
        emit_plain_partition_content "$part_name" "${lv_kind[$lv_name]}" "${lv_mount[$lv_name]}" "$fs_type" "$luks_enabled" "$luks_name"
        cat <<'EOF'
            };
EOF
      done
    fi

    cat <<EOF
          };
        };
      };
EOF
  done

  if [[ "$storage_mode" == "LVM" ]]; then
    cat <<'EOF'
    };
    lvm_vg = {
EOF

    for vg in "${vg_names[@]}"; do
      cat <<EOF
      $vg = {
        type = "lvm_vg";
        lvs = {
EOF
      for lv_name in "${lv_names[@]}"; do
        [[ "${lv_vg[$lv_name]}" == "$vg" ]] || continue
        case "${lv_kind[$lv_name]}" in
          swap)
            emit_swap_lv "$lv_name" "${lv_size[$lv_name]}"
            ;;
          fs)
            emit_fs_lv "$lv_name" "${lv_size[$lv_name]}" "${lv_mount[$lv_name]}" "$fs_type"
            ;;
        esac
      done
      cat <<'EOF'
        };
      };
EOF
    done

    cat <<'EOF'
    };
EOF
  else
    cat <<'EOF'
    };
EOF
  fi

  cat <<'EOF'
  };
}
EOF
} > "$tmp"

disko_file="$(generated_disko_file)"

if [[ -f "$disko_file" ]]; then
  backup="$disko_file.bak.$(date +%Y%m%d%H%M%S)"
  cp "$disko_file" "$backup"
  ui_info "backup: $backup"
fi

install -m 0644 "$tmp" "$disko_file"
write_config_summary "$disko_file"
ui_success "wrote: $disko_file"

if command -v nix-instantiate >/dev/null; then
  nix-instantiate --parse "$disko_file" >/dev/null
  ui_success "nix parse: ok"
else
  ui_info "nix parse: skipped, nix-instantiate is not in PATH"
fi
