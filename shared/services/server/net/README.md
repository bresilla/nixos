# net.bresilla.com: innernet on hive

[innernet](https://github.com/tonarino/innernet) networks coordinated from the `net`
container on hive. Each network is its own interface of the same name: `skynet0`,
then `skynet1`, …

| | |
|---|---|
| Network | `skynet0`, `10.20.0.0/16`, server `10.20.0.1` |
| Endpoint | `ddns.bresilla.net:51820` (UDP, forwarded by the router to hive, then to the container) |
| Page | `https://net.bresilla.com`, only from inside the network; net admins on id.bresilla.com |
| Groups | `servers` 10.20.1.0/24, `laptops` .2, `ci` .3, `devices` .4 |
| Code | `default.nix` (container), `net.py` (page), `devices/minisforum-hm90/services/net.nix` (hive) |

The page reads innernet's database and `wg show`; peers and groups change only
through `innernet-server`'s own commands. Access between groups is the one thing
that command has no subcommand for, so the page writes innernet's `associations`
table itself, as innernet's admin API does.

## Joining a machine

1. On the page, **New peer**: name, group, how long the invitation lasts.
2. Download `<name>.toml`, copy it to the machine, and run there:
   `sudo innernet install --default-name --no-write-hosts <name>.toml`
3. `sudo systemctl start innernet-skynet0`: the unit every machine has
   (`shared/services/network/vpn.nix`) and which starts by itself from then on.
4. Keep the machine's identity: `sudo cat /etc/innernet/skynet0.conf | gopass insert -m services/<host>/innernet/skynet0`.
   On a reinstall, putting it back at `/etc/innernet/skynet0.conf` (mode 0600)
   rejoins without a new invitation.

Without the page, the same on hive: `sudo nixos-container run net -- innernet-server add-peer skynet0 …`.

## Backups

After every change worth keeping the container encrypts two files to the two
YubiKeys (the same recipients as gopass):

- `server.age`: `/etc/innernet-server/skynet0.conf`, the server's private key;
- `db.age`: a SQL dump of `/var/lib/innernet-server/skynet0.db`, without the
  peers' changing endpoints.

Hive copies them to `/var/lib/net-backup/skynet0/` and, by date for 30 days, to
nest (`/mnt/nest/id/net/`). Into gopass, from the laptop:

```sh
bash shared/services/server/net/to-gopass.sh
```

which commits them as `services/hive/innernet/skynet0/{server,db}`.

## Rebuilding on another hive

With the same endpoint and server key, every machine reconnects by itself.

```sh
# on the laptop, with a YubiKey
gopass show services/hive/innernet/skynet0/server > server.conf
gopass show services/hive/innernet/skynet0/db > db.sql
# on the new hive, before the net container first starts (or with it stopped)
c=/var/lib/nixos-containers/net
sudo install -D -m 0600 server.conf $c/etc/innernet-server/skynet0.conf
sudo install -d $c/var/lib/innernet-server
sudo sqlite3 $c/var/lib/innernet-server/skynet0.db < db.sql
sudo systemctl start container@net
```

The container creates a network only when it has no config, so a restored one is
kept as it is. Then point the router's UDP 51820 at the new hive.
