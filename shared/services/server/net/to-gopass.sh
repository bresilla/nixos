#!/usr/bin/env bash
# Copies hive's encrypted copies of an innernet network into the gopass store and
# commits them. They are already encrypted to the store's own recipients, so no
# YubiKey is needed here; one is needed only to read them back.
#   to-gopass.sh [network] [host]      default: skynet0 hive.netbird
set -euo pipefail
net=${1:-skynet0}
host=${2:-hive.netbird}
store=$(gopass config mounts.path 2>/dev/null || echo "$HOME/.local/share/pass")
dir="$store/services/hive/innernet/$net"

mkdir -p "$dir"
for name in server db; do
  scp -q "$host:/var/lib/net-backup/$net/$name.age" "$dir/$name.age.new"
  if cmp -s "$dir/$name.age.new" "$dir/$name.age" 2>/dev/null; then
    rm "$dir/$name.age.new"
  else
    mv "$dir/$name.age.new" "$dir/$name.age"
  fi
done

git -C "$store" add "services/hive/innernet/$net"
if git -C "$store" diff --cached --quiet; then
  echo "gopass already holds hive's latest copies of $net"
else
  git -C "$store" commit -q -m "Save innernet $net from hive"
  git -C "$store" push -q
  echo "saved services/hive/innernet/$net/{server,db} in gopass"
fi
