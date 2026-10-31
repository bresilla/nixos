# hive (Minisforum HM90)

Container host: the OS on the NVMe, container state on two SATA SSDs. It runs
gitea, the binary cache and the Cloudflare tunnel for every public hostname.
nest only stores their data; its side is in
[../beelink-memini](../beelink-memini/README.md).

## Disks

`disko.nix`: the 850 EVO and 860 EVO as one mdadm RAID1, LVM group `data`,
btrfs, mounted at `/var/lib/nixos-containers`, where every NixOS container
keeps its root.

## Network

A direct cable joins hive (`10.99.0.1`, `hive.link`) and nest (`10.99.0.2`,
`nest.link`); the NFS shares use it. The profiles are bound to each
port's MAC address in the devices' `default.nix`.

## Gitea

`gitea/default.nix`: a NixOS container with a private network (`10.231.0.2`)
and user namespace (its uid 3000 is 527288 on the host and on nest). The SQLite
database, config and secret keys stay in the container on hive; repositories,
LFS and attachments are on nest's `/data/gitea` over NFS. Every night the
database and `custom/conf` are copied to `/data/gitea/backups/<date>/` (14 days
kept). The templates and assets under `gitea/` are the branding.

Rebuilding a lost container: update hive, stop gitea, copy the latest
`gitea.db` to `/var/lib/nixos-containers/gitea/var/lib/gitea/data/` and unpack
`conf.tar` into `.../var/lib/gitea/custom/`, then start it. Without a backup,
create the admin with `gitea admin user create` inside the container and
re-adopt the repositories under Site Administration.

## Binary cache

`cache/`: Attic in a NixOS container (`10.231.1.2`, its uid 3001 is 527289 on
the host and on nest). `server.db`, the page's `ui.db`, the pins API's
`pins.json` and both secrets stay in the container's `/var/lib`; chunk files
are on nest's `/data/attic/storage` over NFS. Caddy on 8080 sends `/` and `/-/`
to the page and pins API (`cache/ui.py`), the rest to Attic. The tunnel
publishes it as `https://cache.bresilla.com`; NetBird peers push to
`http://hive.netbird:8080`, which avoids Cloudflare's 100 MB upload cap.
`attic-gc` runs nightly and on every switch: per cache it drops builds that are
unpinned (`packages/pins.json` on main for /packages, the pins API for
/bresilla) and not needed by a pinned one, then frees their data; /kernels is
never pruned. Every night the databases, pins and secrets are copied to
`/data/attic/backups/<date>/` (14 days kept). Accounts for the page:
`sudo cache-ui-user add <name>`.

Rebuilding a lost container: update hive, then inside it (`nixos-container run
cache`) copy the latest backup's `server.db`, `ui.db` and `pins.json` to
`/var/lib/atticd/` and the two `.env` files to `/var/lib/`, all owned by
atticd (0400 for the `.env` files), and restart `atticd` and `cache-ui`. The
container's root cannot read nest's share: read it with `runuser -u atticd`.

## Cloudflare tunnel

`tunnel.nix` runs the locally managed tunnel `hive-nix`; services add their
hostnames to its `ingress`: `git.bresilla.com` and `ssh-git.bresilla.com`
(gitea), `cache.bresilla.com` (the cache container). Machines reach gitea's SSH
through `cloudflared access ssh`, set in `shared/system/remote.nix`.

## Secrets and state outside this repository

| What | Where | Recreate |
| --- | --- | --- |
| Tunnel credentials | `/var/lib/cloudflared-hive-nix.json` (root, 0400) | `cloudflared tunnel token --cred-file <file> hive-nix` after `cloudflared tunnel login` |
| Tunnel `hive-nix` and the DNS records `git`, `ssh-git`, `cache` | Cloudflare | `cloudflared tunnel create hive-nix`, then `cloudflared tunnel route dns hive-nix <name>.bresilla.com`; a new tunnel has a new ID for `tunnel.nix` and `gitea/default.nix` |
| Gitea database, accounts, secret keys | the container on hive; nightly copy on nest | see Gitea above |
| NetBird setup key, `ci` group and its policy (ci → hive TCP 8080) | NetBird dashboard | recreate; the key is ephemeral and reusable |
| Attic token signing key | `/var/lib/atticd.env` in the cache container (atticd, 0400); nightly copy on nest | `printf 'ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64="%s"\n' "$(openssl genrsa -traditional 4096 \| base64 -w0)"`; every issued token then stops working |
| Pins API token | `/var/lib/cache-ui.env` in the cache container (atticd, 0400) | `printf 'CACHE_PIN_TOKEN=%s\n' "$(head -c 32 /dev/urandom \| base64 \| tr -d '/+=')"`, then update `PIN_TOKEN` in GitHub |
| Caches `bresilla`, `packages`, `kernels` and their signing keys | `server.db` in the cache container; nightly copy on nest | `attic cache create home:<name>` and `attic cache configure home:<name> --public`; a new cache has a new public key, so `shared/caches.json` and `flake.nix` need it too |
| GitHub secrets `ATTIC_TOKEN`, `PIN_TOKEN`, `NETBIRD_SETUP_KEY` | bresilla/nixos, and the termworks, paneworks and ai-nerv orgs | token: `atticd-atticadm make-token --sub github-ci --validity 1y --pull '*' --push '*'` inside the container; set with `gh secret set` (`--org <org> --visibility all` for the orgs) |
