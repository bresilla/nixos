#!/usr/bin/env bash
set -euo pipefail
repo="${1:?staged repository required}"
target="${2:?identity directory required}"
device="${3:-}"
identity=(machine.nix user.nix dotfiles.nix boot-hardware.json hardware.nix disko.nix)

mkdir -p -- "$target"
# An older full checkout moves aside once, so only identity stays.
if [[ -e "$target/flake.nix" ]]; then
  old="$target.old-checkout"
  [[ ! -e "$old" ]] || old="$old.$(date +%Y%m%d%H%M%S)"
  mkdir -p -- "$old"
  shopt -s dotglob nullglob
  for entry in "$target"/*; do
    name="${entry##*/}"
    [[ " ${identity[*]} " == *" $name "* ]] && continue
    mv -- "$entry" "$old/"
  done
  shopt -u dotglob nullglob
  echo "Moved the previous checkout in $target to $old."
fi

for name in "${identity[@]}"; do
  if [[ -e "$repo/$name" ]]; then cp -a --no-preserve=ownership -- "$repo/$name" "$target/$name"; fi
done
# A device the repository does not commit is part of this machine's identity.
if [[ -n "$device" && -d "$repo/devices/$device" ]] \
    && ! git -C "$repo" ls-files --error-unmatch "devices/$device/device.json" >/dev/null 2>&1; then
  mkdir -p -- "$target/devices"
  rm -rf -- "${target:?}/devices/$device"
  cp -a --no-preserve=ownership -- "$repo/devices/$device" "$target/devices/$device"
fi
