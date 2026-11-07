# Checks a CI container's own Nix: its store, its evaluation sandbox, cleanup
# sparing what it runs on, and one tiny build per system in the machines file.
echo "  own store: $(stat -c '%U:%G %a' /nix/store), writable: $(touch /nix/store/.w 2>/dev/null && rm /nix/store/.w && echo yes || echo no)"

if why=$(systemd-run --quiet --wait --pipe --collect "$(command -v bwrap)" --unshare-all --share-net --die-with-parent \
  --ro-bind /proc /proc --dev /dev --ro-bind /nix/store /nix/store "$(command -v true)" 2>&1)
then echo "  eval sandbox: ok"; else echo "  eval sandbox: failed ($(echo "$why" | tail -1))"; fi

dead=$(comm -12 <(nix-store --gc --print-dead 2>/dev/null | sort) <(nix-store -qR /run/current-system | sort) | wc -l)
echo "  cleanup would remove $dead of its own paths"

machines=/var/lib/ci/machines
[ -s "$machines" ] || { echo "  builders: none"; exit 0; }
for sys in $(awk '!/^#/ && NF { print $2 }' "$machines" | tr , '\n' | sort -u); do
  expr='derivation { name = "ci-check"; system = "'"$sys"'"; builder = "/bin/sh"; t = builtins.currentTime;
    args = [ "-c" "n=0; while read -r l; do case $l in processor*) n=$((n+1));; esac; done </proc/cpuinfo; echo $n >$out" ]; }'
  if out=$(timeout 300 nix build --impure --no-link --print-out-paths --expr "$expr" 2>&1); then
    echo "  build $sys: ok on a $(cat "$out")-cpu builder"
  else
    echo "  build $sys: failed ($(echo "$out" | tail -1))"
  fi
done
