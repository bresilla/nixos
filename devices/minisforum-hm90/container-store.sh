# Fills /nix/var/nix/container-stores/$INSTANCE with hardlinks of what the
# container and its unit run, which becomes the only /nix/store they see.
# Hive mounts /nix/store on its own and hardlinks cannot cross mounts, so this
# works through a plain bind of /nix (the unit has private mounts).
nix=$(mktemp -d)
mount --bind /nix "$nix"
farm=$nix/var/nix/container-stores/$INSTANCE
mkdir -p "$farm"
chmod 0755 "$farm"

declare -A want
roots=$( {
  echo "$SYSTEM_PATH"
  systemctl show "container@$INSTANCE" -p ExecStartPre -p ExecStart -p ExecStartPost -p ExecReload -p Environment \
    | grep -oE '/nix/store/[a-z0-9]{32}-[^/ ;"]+'
} | sort -u)
# shellcheck disable=SC2086
for p in $(nix-store -qR $roots); do want[${p#/nix/store/}]=1; done

# The module and nspawn read these of hive's /etc, which link through hive's
# own /etc store path; only they are carried over, with what they point to.
hostEtc=(resolv.conf os-release)
etcName=$(basename "$(dirname "$(readlink /etc/static)")")
for f in "${hostEtc[@]}"; do
  t=$(readlink "/etc/static/$f" || true)
  case $t in /nix/store/*) t=${t#/nix/store/}; want[${t%%/*}]=1 ;; esac
done

for e in "$farm"/* "$farm"/.new; do
  [ -e "$e" ] || [ -L "$e" ] || continue
  [ -n "${want[$(basename "$e")]-}" ] || rm -rf "$e"
done

for n in "${!want[@]}"; do
  [ -e "$farm/$n" ] || [ -L "$farm/$n" ] && continue
  cp -a --link "$nix/store/$n" "$farm/.new"
  mv "$farm/.new" "$farm/$n"
done

rm -rf "${farm:?}/$etcName"
mkdir -p "$farm/$etcName/etc"
for f in "${hostEtc[@]}"; do cp -a --link "$nix/store/$etcName/etc/$f" "$farm/$etcName/etc/"; done
