# nest (Beelink ME mini)

Storage server: the OS on the 58 GB eMMC, data on four 2 TB NVMe drives. It
only stores data, which hive's containers use over NFS. hive's side is in
[../hive](../hive/README.md).

## Disks

`storage.nix` draws the layout: two mdadm RAID1 pairs (md0 = the two 980 PRO,
md1 = 990 PRO + 990 EVO), one LVM group `data` over both, btrfs on top, and one
subvolume per share under `/data`. Each disk of a pair is a full copy: a dead
drive is swapped and rebuilt with `mdadm --add`. `cat /proc/mdstat` shows the state.

A full reinstall formats every disk in `storage.nix`, the eMMC included. To
re-create only the data disks, run disko on a copy of the layout without the
eMMC disk and its `pool` group.

## Shares

Every share is listed once, in `shares.nix`: its owner as hive's container sees it,
whether it has the `config/` and `data/` layout, and whether it is backed up. From
that list come the subvolumes (`storage.nix`), their owners and folders
(`services/subvolumes.nix`, on every boot), the NFS exports to hive over the direct
link (`services/nfs.nix`) and what dump copies. A new share is a new entry there.

In a share, `config/` is root's and holds only encrypted copies (hive's `keep`, and
`@vault/config/dump/` with dump's own state); `data/` belongs to the service.

| Share | Holds | Owner |
| --- | --- | --- |
| `/data/git` | Gitea repositories, LFS, attachments, nightly database copies (3 days) | gitea, 527288 |
| `/data/cache` | the cache's databases and pins, nightly copies (3 days) | atticd, 527289 |
| `/data/cache-chunks` | the cache's chunk files, mounted inside `cache/data/storage`; not backed up, CI pushes builds again | atticd, 527289 |
| `/data/id` | Kanidm's nightly backups in `data/kanidm` (3 days) | root |
| `/data/s3` | s3.bresilla.com's buckets and RustFS's metadata | rustfs, 527290 |
| `/data/build` | build.bresilla.com's nightly database copies (3 days) | root |
| `/data/vault` | the vault's nightly database copies (3 days) | root |
| `/data/net` | innernet's encrypted database copies (3 days) and server key | root |

## Backups

- **Snapshots** (`services/backup.nix`): btrbk snapshots every backed-up share at
  :30 each hour, named in UTC, into `/mnt/data-store/.snapshots`; kept 48 hours,
  then the 05:30 UTC one daily for 7 days. A monthly scrub checks the data pool and
  the eMMC.
- **dump** (`services/dump.nix`, `shared/services/dump`): nest's manager pushes the
  newest snapshots each night to the targets listed on status.bresilla.com (a disk
  on tron today, kept 14 days, 8 weeks, 12 months) and to restic targets. Its key,
  restic passwords and rclone login are copied, encrypted to the YubiKeys, to
  `@vault/config/dump/dump.tar.age` every hour.
- **Status** (`services/status.nix`): disks, RAID, SMART, btrfs errors, scrubs,
  snapshots and units, served read-only to hive on `10.99.0.2:9101`.

A share restores from its newest snapshot, or from a dump target's copy:
`btrfs send` it back and swap it in for the share while its service is stopped.
