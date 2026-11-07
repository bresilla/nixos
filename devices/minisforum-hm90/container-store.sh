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

# The module copies hive's resolv.conf, which links through hive's own /etc.
etc=$(readlink /etc/static)
etcName=$(basename "$(dirname "$etc")")
want[$etcName]=1

for e in "$farm"/* "$farm"/.new; do
  [ -e "$e" ] || [ -L "$e" ] || continue
  [ -n "${want[$(basename "$e")]-}" ] && [ "$(basename "$e")" != "$etcName" ] || rm -rf "$e"
done

for n in "${!want[@]}"; do
  [ "$n" = "$etcName" ] && continue
  [ -e "$farm/$n" ] || [ -L "$farm/$n" ] && continue
  cp -a --link "$nix/store/$n" "$farm/.new"
  mv "$farm/.new" "$farm/$n"
done

mkdir -p "$farm/$etcName/etc"
ln -s "$(readlink /etc/static/resolv.conf)" "$farm/$etcName/etc/resolv.conf"
