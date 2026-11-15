#!/usr/bin/env bash
# Copies a server's encrypted secrets into gopass and commits them. They are already
# encrypted to the store's own recipients, so no YubiKey is needed here; one is needed
# only to read them back (README.md).
#   to-gopass.sh [host] [address]      default: hive hive.netbird
set -euo pipefail
host=${1:-hive}
address=${2:-$host.netbird}
store=$(gopass config mounts.path 2>/dev/null || echo "$HOME/.local/share/pass")
dir="$store/services/$host/keep"

mkdir -p "$dir"
for remote in $(ssh "$address" 'ls /var/lib/server-keep/*.age'); do
  name=$(basename "$remote")
  scp -q "$address:$remote" "$dir/$name.new"
  if cmp -s "$dir/$name.new" "$dir/$name" 2>/dev/null; then rm "$dir/$name.new"; else mv "$dir/$name.new" "$dir/$name"; fi
done

git -C "$store" add "services/$host/keep"
if git -C "$store" diff --cached --quiet; then
  echo "gopass already holds $host's latest secrets"
else
  git -C "$store" commit -q -m "Save $host's secrets"
  git -C "$store" push -q
  echo "saved $(ls "$dir" | sed 's/\.age$//' | tr '\n' ' ')in services/$host/keep/"
fi
