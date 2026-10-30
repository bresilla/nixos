# nest (Beelink ME mini)

Storage server: the OS on the 58 GB eMMC, data on four 2 TB NVMe drives. It
only stores data, which hive's containers use over NFS. hive's side is in
[../minisforum-hm90](../minisforum-hm90/README.md).

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

## Shares

NFSv4 over the direct link, to hive only (`nfs.nix`): `/data/gitea` for gitea's
repositories and `/data/attic` for the binary cache's chunk files and nightly
database backups. Both services run in containers on hive.

## State outside this repository

| What | Where | Recreate |
| --- | --- | --- |
| Gitea repositories, LFS, attachments, nightly database backups | `/data/gitea` | restore from a copy of `/data/gitea` |
| Cache chunk files, nightly database and secrets backups | `/data/attic` | CI pushes the builds again on the next run or release tag; see hive's README |
