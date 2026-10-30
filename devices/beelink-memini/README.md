# nest (Beelink ME mini)

Storage server: the OS on the 58 GB eMMC, data on four 2 TB NVMe drives. It
serves gitea's data to hive over NFS and runs the binary cache
`cache.bresilla.com`. hive's side is in [../minisforum-hm90](../minisforum-hm90/README.md).

## Disks

`disko.nix` draws the layout: two mdadm RAID1 pairs (md0 = the two 980 PRO,
md1 = 990 PRO + 990 EVO), one LVM group `data` over both, btrfs on top, and one
subvolume per share under `/data`. Each disk of a pair is a full copy: a dead
drive is swapped and rebuilt with `mdadm --add`. `cat /proc/mdstat` shows the state.

`subvolumes.nix` creates any subvolume that disko declares but the live
filesystem lacks, and sets `/data/gitea` to hive's gitea owner (527288), on
every boot. A new share is a new entry in `disko.nix`, nothing more.

A full reinstall formats every disk in `disko.nix`, the eMMC included. To
re-create only the data disks, run disko on a copy of the layout without the
eMMC disk and its `pool` group.

## Binary cache

Attic stores everything in `/data/attic` (database `server.db`, chunk files in
`storage/`, the pins API's `pins.json`). Caddy on port 8080 sends `/` and `/-/`
to the page and pins API (`cache/ui.py`) and the rest to Attic. hive's
Cloudflare tunnel publishes it as `https://cache.bresilla.com`; NetBird peers
can use `http://nest.netbird:8080` directly, which avoids Cloudflare's 100 MB
upload cap. `attic-gc` runs nightly and on every switch: it drops builds that
are neither in `packages/pins.json` on main nor in the pins API, then frees
their data.

## Secrets and state outside this repository

| What | Where | Recreate |
| --- | --- | --- |
| Attic token signing key | `/var/lib/atticd.env` (root, 0600) | `printf 'ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64="%s"\n' "$(openssl genrsa -traditional 4096 \| base64 -w0)"`; every issued token then stops working |
| Pins API token | `/var/lib/cache-ui.env` (root, 0600) | `printf 'CACHE_PIN_TOKEN=%s\n' "$(head -c 32 /dev/urandom \| base64 \| tr -d '/+=')"`, then update `PIN_TOKEN` in GitHub |
| Cache `bresilla`, its signing key | `/data/attic/server.db` | `attic cache create home:bresilla` and `attic cache configure home:bresilla --public`; a new cache has a new public key, so `shared/caches.json` and `flake.nix` need it too |
| Cached builds and pins | `/data/attic` | CI pushes them again on the next run or release tag |
| Gitea repositories, LFS, attachments, nightly database backups | `/data/gitea` | restore from a copy of `/data/gitea` |
| GitHub secrets `ATTIC_TOKEN`, `PIN_TOKEN`, `NETBIRD_SETUP_KEY` | bresilla/nixos, and the termworks, paneworks and ai-nerv orgs | token: `sudo atticd-atticadm make-token --sub github-ci --validity 1y --pull bresilla --push bresilla`; set with `gh secret set` (`--org <org> --visibility all` for the orgs) |

Losing `/var/lib/atticd.env` only invalidates tokens; losing `server.db` loses
the cache and its signing key. Back up `/data/attic/server.db` together with
`/var/lib/atticd.env` and `/var/lib/cache-ui.env`.
