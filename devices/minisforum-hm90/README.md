# hive (Minisforum HM90)

Container host: the OS on the NVMe, container state on two SATA SSDs. It runs
gitea and the Cloudflare tunnel for every public hostname. nest's side is in
[../beelink-memini](../beelink-memini/README.md).

## Disks

`disko.nix`: the 850 EVO and 860 EVO as one mdadm RAID1, LVM group `data`,
btrfs, mounted at `/var/lib/nixos-containers`, where every NixOS container
keeps its root.

## Network

A direct cable joins hive (`10.99.0.1`, `hive.link`) and nest (`10.99.0.2`,
`nest.link`); NFS and the cache traffic use it. The profiles are bound to each
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

## Cloudflare tunnel

`tunnel.nix` runs the locally managed tunnel `hive-nix`; services add their
hostnames to its `ingress`: `git.bresilla.com` and `ssh-git.bresilla.com`
(gitea), `cache.bresilla.com` (nest's cache). Machines reach gitea's SSH
through `cloudflared access ssh`, set in `shared/system/remote.nix`.

## Secrets and state outside this repository

| What | Where | Recreate |
| --- | --- | --- |
| Tunnel credentials | `/var/lib/cloudflared-hive-nix.json` (root, 0400) | `cloudflared tunnel token --cred-file <file> hive-nix` after `cloudflared tunnel login` |
| Tunnel `hive-nix` and the DNS records `git`, `ssh-git`, `cache` | Cloudflare | `cloudflared tunnel create hive-nix`, then `cloudflared tunnel route dns hive-nix <name>.bresilla.com`; a new tunnel has a new ID for `tunnel.nix` and `gitea/default.nix` |
| Gitea database, accounts, secret keys | the container on hive; nightly copy on nest | see Gitea above |
| NetBird setup key, `ci` group and its policy (ci → nest TCP 8080) | NetBird dashboard | recreate; the key is ephemeral and reusable |
