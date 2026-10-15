#!/usr/bin/env bash

set -euo pipefail

# configs/ of the repository cloned in ~/.dot; this links it on non-NixOS systems.
ENVY="$(cd "$(dirname "$0")" && pwd)"

link_replace() {
    local source="$1"
    local target="$2"

    mkdir -p "$(dirname "$target")"
    rm -rf -- "$target"
    ln -s "$source" "$target"
}

mkdir -p "$HOME/.config"
shopt -s nullglob dotglob
for target in "$HOME/.config"/*; do
    [[ -L "$target" ]] || continue
    rm -f -- "$target"
done
for item in "$ENVY"/assets/*; do
    link_replace "$item" "$HOME/.config/$(basename "$item")"
done
for item in "$ENVY"/home/*; do
    link_replace "$item" "$HOME/$(basename "$item")"
done
shopt -u nullglob dotglob
