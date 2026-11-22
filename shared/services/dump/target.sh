# dump-target VERB ARGS: the only disk work the dump manager may do here, as root.
# Disks are named by their /dev/disk/by-id name plus the serial typed on the status page.
set -euo pipefail

die() { echo "dump-target: $*" >&2; exit 2; }
check_name() { [[ ${1:-} =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "bad target name"; }
lv_of() { echo "/dev/dump-$1/$1"; }
mnt_of() { echo "/mnt/dump/$1"; }

# A whole disk by its by-id name, only if its serial is the one given.
disk_of() {
  [[ ${1:-} =~ ^[A-Za-z0-9._:-]+$ ]] || die "bad disk id"
  [[ ${2:-} =~ ^[A-Za-z0-9._:-]+$ ]] || die "bad serial"
  local dev
  dev=$(readlink -f "/dev/disk/by-id/$1")
  [ -b "$dev" ] || die "no disk $1"
  [ "$(lsblk -dno TYPE "$dev")" = disk ] || die "$1 is not a whole disk"
  [ "$(lsblk -dno SERIAL "$dev" | xargs)" = "$2" ] || die "the serial of $1 does not match"
  echo "$dev"
}

blank() {
  [ "$(lsblk -nro NAME "$1" | wc -l)" = 1 ] && [ -z "$(lsblk -dno FSTYPE "$1")" ] && [ -z "$(wipefs "$1")" ]
}

verb=${1:-}
shift || true
case $verb in
  probe)
    lsblk -J -b -o NAME,PATH,SIZE,MODEL,SERIAL,TYPE,TRAN,FSTYPE,MOUNTPOINTS
    echo '---'
    for l in /dev/disk/by-id/*; do
      case "$l" in *-part[0-9]*|*/wwn-*|*/nvme-eui*|*/lvm-*|*/dm-*) continue ;; esac
      echo "$l $(readlink -f "$l")"
    done
    ;;
  lv)
    check_name "${1:-}"
    if [ -b "$(lv_of "$1")" ]; then lv_of "$1"; fi
    ;;
  format)
    check_name "${1:-}"
    dev=$(disk_of "${2:-}" "${3:-}")
    blank "$dev" || die "the disk is not blank; it was not touched"
    [ ! -e "/dev/dump-$1" ] || die "dump-$1 already exists"
    pvcreate -ff -y "$dev"
    vgcreate "dump-$1" "$dev"
    lvcreate -y -l 100%FREE -n "$1" "dump-$1"
    mkfs.btrfs -L "dump-$1" "$(lv_of "$1")"
    ;;
  mount)
    check_name "${1:-}"
    m=$(mnt_of "$1")
    opts=noatime,compress=zstd:3,nosuid,nodev,noexec
    mkdir -p "$m"
    if mountpoint -q "$m"; then mount -o "remount,$opts" "$m"; else mount -o "$opts" "$(lv_of "$1")" "$m"; fi
    mkdir -p "$m/nest"
    ;;
  umount)
    check_name "${1:-}"
    umount "$(mnt_of "$1")" 2>/dev/null || true
    ;;
  wipe)
    check_name "${1:-}"
    dev=$(disk_of "${2:-}" "${3:-}")
    [ "$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | xargs)" = "dump-$1" ] || die "the disk is not dump-$1's"
    umount "$(mnt_of "$1")" 2>/dev/null || true
    lvremove -f "$(lv_of "$1")"
    vgremove -f "dump-$1"
    wipefs -a "$dev"
    ;;
  report)
    check_name "${1:-}"
    m=$(mnt_of "$1")
    if mountpoint -q "$m"; then echo mounted; else echo unmounted; fi
    df -B1 --output=size,used,avail "$m" | tail -1
    find "$m/nest" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null || true
    echo
    btrfs device stats "$m" 2>/dev/null | awk '{s += $2} END {print s + 0}'
    ;;
  *)
    die "usage: dump-target probe|lv|format|mount|umount|wipe|report"
    ;;
esac
