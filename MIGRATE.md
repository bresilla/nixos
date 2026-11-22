# Nest shares: one per service, config and data, backed up by btrbk

Each phase ends in a check, and nothing old is deleted until the new layout has run
for a week.

## Status (2026-11-21)

- Phases 1, 2 and 3: done.
- Phase 4, changed: the WD USB drive dropped off USB under sustained writes (two
  enclosures, two ports) and was retired. Off-nest copies are now "dump"
  (services/dump): targets added and removed on status.bresilla.com, nest pushes to them
  over SSH with btrbk. First target: tron's 4 TB SSD; restore check passed for all 7
  shares on 2026-11-22. Left: step 5 (services' own retention to 3).
- The cache's chunks are the top-level `@cache-chunks` (`/data/cache-chunks`), mounted
  on hive at `/mnt/nest/cache/data/storage`, not a nested subvolume: NFS showed the
  nested one as a file system loop. btrbk still leaves the chunks out.
- 2026-11-21: `@gitea`, `@attic`, the nested `@cache/data/storage` and the `/data/gitea`,
  `/data/attic` exports deleted, a week early at the user's request.
- Phase 5: covered by dump: another machine's disk, or a restic repository online, is one
  more target on the status page.

## Target

One btrfs subvolume ("share") per service on nest, named after its address, each with
two folders:

- `config/`: the service's secrets and settings, encrypted to both YubiKeys (`.age`),
  the same sets `services/keep` makes today.
- `data/`: what the service builds up: databases (the nightly copies) and files.

| Share | `config/` (encrypted) | `data/` | Owner of `data/` |
|---|---|---|---|
| `@git` | gitea's keys and conf, mirror token, Radicle identity (keep set `gitea`) | `repositories/`, `lfs/`, `attachments/`, `backups/` (gitea.db + conf.tar) | 527288 (gitea) |
| `@cache` | Attic's signing secret, page secret, CI WireGuard key (keep set `cache`) | `backups/` (server.db, ui.db, pins.json, env), `storage/` = chunks, a nested subvolume | 527289 (atticd) |
| `@build` | attic and pin tokens, murosd token secret, builder key (keep set `ci`) | `server.db`, `frontend.db` (nightly copies) | root |
| `@id` | every site's sign-in secret (keep set `logins`) | Kanidm's backups | root |
| `@vault` | the vault's signing key (keep set `vault`) | Vaultwarden's backups (database, attachments, Sends) | root |
| `@net` | innernet's server keys (`server.age`) | innernet's database (`db.age`) | root |
| `@s3` | RustFS's admin key (keep set `s3`) | the buckets | 527290 (rustfs) |

Rules:
- Each share is one NFS export to hive (`10.99.0.1`), mounted on hive at
  `/mnt/nest/<share>`.
- A container binds only its share's `data/`, at the same path it uses today
  (`/srv/gitea`, `/srv/attic`, `/srv/s3`), so nothing changes inside the containers.
- `config/` is written by hive's root only (the keep job); no container sees it.
- Hive-wide keep sets (`ssh`, `tunnel`) are not a service's: they stay in gopass only.

## Today

| Subvolume | Mounted on hive | Holds |
|---|---|---|
| `@gitea` | `/mnt/nest/gitea` → gitea `/srv/gitea` | repositories, lfs, attachments, backups/ (14 days) |
| `@attic` | `/mnt/nest/attic` → cache `/srv/attic` | storage/ (chunks), backups/ (14 days) |
| `@id` | `/mnt/nest/id` (host only) | kanidm/, vault/, net/ (30 days each) |
| `@s3` | `/mnt/nest/s3` → s3 `/srv/s3` | data/ (RustFS volume) |

Build (`ci` container) has no share: its `server.db` and `frontend.db` exist only on hive.
Nothing on nest has snapshots or a second copy.

## Phase 1: new shares on nest (no downtime)

1. `devices/nest/storage.nix`: add `@build`, `@vault`, `@net` beside the others.
2. `devices/nest/services/subvolumes.nix`: owners for the new ones (root), and create
   `config/` (root, 0700) and `data/` (the service's owner, 0750) in every share.
3. `devices/nest/services/nfs.nix`: export `/data/build`, `/data/vault`, `/data/net`.
4. Deploy nest. Check: `btrfs subvolume list /data`, `exportfs -v`.

## Phase 2: the services without live data on nest (no downtime)

For `@build`, `@vault`, `@net`, `@id`:

1. Hive mounts `/mnt/nest/build`, `/mnt/nest/vault`, `/mnt/nest/net` (each `host.nix`,
   `nofail`, like `/mnt/nest/id`).
2. `services/vault/host.nix`: `vault-backup` writes to `/mnt/nest/vault/data/<date>`.
3. `services/net/host.nix`: `net-backup-copy-*` writes `db.age` to
   `/mnt/nest/net/data/<net>/<date>` and `server.age` to `/mnt/nest/net/config/<net>/`.
4. `services/ci/host.nix`: new `build-backup` (03:40 UTC): SQLite `.backup` of
   `/var/lib/murosd/server.db` and `/var/lib/muros-ui/frontend.db` into
   `/mnt/nest/build/data/<date>`.
5. `services/id/host.nix`: `id-backup` writes to `/mnt/nest/id/data/kanidm`.
6. `services/keep`: after encrypting a set, also copy `<set>.age` to its share's
   `config/` (gitea→git, cache→cache, ci→build, logins→id, vault→vault, s3→s3).
7. Move the old copies: `@id/vault/*` → `@vault/data/`, `@id/net/*` → `@net/data/`,
   `@id/kanidm` → `@id/data/kanidm` (same filesystem: `mv` across subvolumes copies, so
   use `cp -a --reflink=always`, then remove the old folders).
8. Deploy hive. Check: run each backup unit by hand, look at the files on nest.

## Phase 3: renames with live data (short downtime, one service at a time)

On nest, `@git` and `@cache` are made as snapshots of the old subvolumes, which is
instant, then their contents are moved into `data/` (an `mv` inside one subvolume is
instant too).

**gitea → `@git`** (gitea down for a few minutes):
1. On hive: stop `container@gitea`, unmount `/mnt/nest/gitea`.
2. On nest, with the top of the filesystem mounted (`subvol=/`):
   `btrfs subvolume snapshot @gitea @git`, then in `@git`: `mkdir data config` and
   move `repositories lfs attachments backups` into `data/`.
3. nest: `storage.nix` gets `@git` at `/data/git`; `nfs.nix` exports `/data/git`.
4. hive: `services/gitea/host.nix` mounts `nest.link:/data/git` at `/mnt/nest/git`
   and binds `/mnt/nest/git/data` to `/srv/gitea`.
5. Deploy nest, then hive. Check: gitea starts, a push and a clone work, LFS and
   attachments load.

**attic → `@cache`** (cache down for a few minutes; every update stalls meanwhile,
so do it when nothing builds):
1. On hive: stop `container@cache`, unmount `/mnt/nest/attic`.
2. On nest: `btrfs subvolume snapshot @attic @cache`; in `@cache`: `mkdir data config`,
   move `backups` into `data/`, `btrfs subvolume create data/storage` and
   `cp -a --reflink=always storage/. data/storage/`, then remove the old `storage`.
   A btrfs snapshot never includes a nested subvolume, so btrbk skips the chunks.
3. nest: `@cache` at `/data/cache`, exported. hive: `services/cache/host.nix` mounts
   `/mnt/nest/cache` and binds `/mnt/nest/cache/data` to `/srv/attic`.
4. Deploy nest, then hive. Check: `cache.bresilla.com` serves, a push works, the pins
   page lists every pin.

**s3** (s3 down for a minute, no rename):
1. In `@s3`: `mkdir config`; the buckets are already in `data/`.
2. hive: bind `/mnt/nest/s3/data` to `/srv/s3`, `RUSTFS_VOLUMES = "/srv/s3"`.
3. Check: the console lists the buckets, an upload and download work.

After a week without trouble: delete `@gitea` and `@attic`, and the old exports.

## Phase 4: btrbk and the USB SSD

The SanDisk Extreme 2 TB on nest (`/dev/disk/by-id/usb-SanDisk_Extreme_55AE_*`).
**Wiping it needs an explicit yes:** it still holds the music (copied to `game`
`D:\music`, verified) and the robotics data and code on its ext4 half.

1. Encryption, if wanted: `dm_crypt` and its crypto modules into
   `devices/nest/modules.txt`, then a reboot of nest (module loading is locked).
   Key file on nest's internal disk, a copy in gopass.
2. Format: LUKS + btrfs, mounted at `/mnt/backup` with `nofail`.
3. `services.btrbk` on nest:
   - volume: the top of `data-store` (`subvol=/`), snapshots in `/.snapshots`
   - subvolumes: `@git @cache @build @id @vault @net @s3`
   - snapshots on nest: hourly for 24 h, daily for 7 days
   - target `/mnt/backup`: daily 14, weekly 8, monthly 12
   - nightly run at 05:00 UTC, after the last service copy (04:30 UTC)
4. Monthly `btrfs scrub` of the SSD; a failed run raises an alert.
5. The services' own retention drops to 3 copies (btrbk keeps the history).
6. Check: `btrbk list all`, then restore one file from the SSD.

## Phase 5: off-site (to be decided)

A btrfs box elsewhere pulls the same snapshots from nest over NetBird (btrbk with an
`ssh://` source, pull mode, so nest holds no login to it). Or restic from the newest
snapshot to a rented storage box. Same shares, longer retention.

## Open

- LUKS on the SSD (one reboot of nest), or plain btrfs?
- The SSD's ext4 half: wipe as is?
- Retention numbers above.
- The off-site machine.
