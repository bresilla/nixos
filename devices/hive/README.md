# hive (Minisforum HM90)

Container host: the OS on the NVMe, container state on two SATA SSDs. It runs
gitea, the binary cache, CI, id, s3 and the Cloudflare tunnel for every public hostname.
nest only stores their data; its side is in
[../nest](../nest/README.md). The services themselves live in [../../services](../../services);
`default.nix` enables the ones hive hosts.

## Disks

`storage.nix`: the 850 EVO and 860 EVO as one mdadm RAID1, LVM group `data`,
btrfs, mounted at `/var/lib/nixos-containers`, where every NixOS container
keeps its root.

## Network

A direct cable joins hive (`10.99.0.1`, `hive.link`) and nest (`10.99.0.2`,
`nest.link`); the NFS shares use it. The profiles are bound to each
port's MAC address in the devices' `default.nix`.

## Gitea

`services/gitea/host.nix`, with the container in `services/gitea/`: a NixOS container with a private network (`10.231.0.2`)
and user namespace (its uid 3000 is 527288 on the host and on nest). The SQLite
database, config and secret keys stay in the container on hive; repositories,
LFS and attachments are on nest's `/data/gitea` over NFS. Every night the
database and `custom/conf` are copied to `/data/gitea/backups/<date>/` (14 days
kept). The templates and assets in that shared module are the branding.

Rebuilding a lost container: update hive, stop gitea, copy the latest
`gitea.db` to `/var/lib/nixos-containers/gitea/var/lib/gitea/data/` and unpack
`conf.tar` into `.../var/lib/gitea/custom/`, then start it. Without a backup,
create the admin with `gitea admin user create` inside the container and
re-adopt the repositories under Site Administration.

## Binary cache

`services/cache/host.nix`, with the container in `services/cache/`: Attic in a NixOS container (`10.231.1.2`, its uid 3001 is 527289 on
the host and on nest). `server.db`, the page's `ui.db`, the pins API's
`pins.json` and both secrets stay in the container's `/var/lib`; chunk files
are on nest's `/data/attic/storage` over NFS. Caddy on 8080 sends `/` and `/-/`
to the page and pins API (`services/cache/ui.py`), the rest to Attic. The tunnel
publishes it as `https://cache.bresilla.com`; NetBird peers push to
`http://hive.netbird:8080`, which avoids Cloudflare's 100 MB upload cap.
`attic-gc` runs nightly and on every switch: per cache it drops builds that are
unpinned (pins set by build.bresilla.com through the pins API) and not needed by
a pinned one, or that cache.nixos.org already has, then frees their data; /kernels
is never pruned. Every night the databases, pins and secrets are copied to
`/data/attic/backups/<date>/` (14 days kept). People sign in with
id.bresilla.com: the `cache_users` group may sign in, `cache_admins` may manage.

Rebuilding a lost container: update hive, then inside it (`nixos-container run
cache`) copy the latest backup's `server.db`, `ui.db` and `pins.json` to
`/var/lib/atticd/` and the two `.env` files to `/var/lib/`, all owned by
atticd (0400 for the `.env` files), and restart `atticd` and `cache-ui`. The
container's root cannot read nest's share: read it with `runuser -u atticd`.

## id

`services/id/host.nix`, with the container in `services/id/`: Kanidm in
a NixOS container (`10.231.3.2`), the one sign-in for git, cache and build at
`id.bresilla.com`. People and groups are declared in `id.nix`; `sudo id-enroll
<name>` makes a one-day link to set a passkey. Kanidm backs itself up every
night at 03:00 UTC inside the container (7 kept); at 03:20 UTC hive copies new
ones to nest's `/data/id/kanidm/` (30 days kept). The container never needs
nest.

Restoring: inside the container (`nixos-container run id`), stop `kanidm`, run
`kanidmd database restore -c <the -c file of kanidm.service> <backup.json>`
with a copy from nest, and start it again. A lost account without a backup:
`kanidmd recover-account <name>` there.

## s3

`services/s3/host.nix`, with the container in `services/s3/`: RustFS in
a NixOS container (`10.231.4.2`, its uid 3002 is 527290 on the host and on
nest). Buckets are on nest's `/data/s3/data` over NFS; the root key
(`/var/lib/s3/root.env`, made once) and RustFS's logs stay in the container.
RustFS comes from nixpkgs-unstable, as nixos-26.05 lacks it. Caddy on 80 serves
the console at `/rustfs/console/` from `console.nix`, RustFS's own console
build with the shared header, tokens and accent (its `themes/<id>` hook plus
`console.patch`); every other path is the S3 API. The tunnel publishes it as
`https://s3.bresilla.com`; NetBird peers reach the API at
`http://hive.netbird:9000`, which avoids Cloudflare's 100 MB upload cap.

People sign in to the console with id.bresilla.com: `s3_users` get RustFS's
`readwrite` policy, `s3_admins` `consoleAdmin`, through the `s3_policy` claim.
S3 clients use access keys made in the console. The console itself offers only
id.bresilla.com; the root key (`root` and the secret in `root.env`) still works
for S3 clients, for when id is down.

## vault

`services/vault/host.nix`, with the container in `services/vault/`:
Vaultwarden in a NixOS container (`10.231.5.2`), as `vault.bresilla.com`. It is
never public: no DNS record, no tunnel route. Every machine resolves the name
from `shared/system/hosts.nix` to hive's overlay address, and hive listens on
443 only there (`vault-overlay`). Moving to another overlay changes that line in
`hosts.nix` and `overlay` in `vault.nix`. Phones have no hosts file, so they
need the overlay's own DNS or a name entry in their app setup.

Sign-in is only through id.bresilla.com (`SSO_ONLY`; the `vault_users` group),
with no sign-up, invitations, password hints or `/admin` page. The vault data
is still encrypted with each person's master password, which neither hive nor
id ever sees: keep it long and random, in gopass, so a copy of the database is
useless without it.

Its certificate comes from bresilla's own CA (see cert below): Caddy asks it
over ACME for a one-day certificate and renews it, with nothing outside
involved. Until the CA exists, Caddy uses a self-signed stand-in. The web vault
is the stock build with the shared header, tokens and accent added
(`vault.css`, `adapter.js`); use the browser extension and the apps rather than
the web vault for passwords.

## cert

`services/ca/host.nix`, with the container in `services/ca/`: step-ca in a
NixOS container (`10.231.6.2`), as `cert.bresilla.com:8443`, reached like the
vault only over the overlay. It signs only names under `bresilla.com`, over ACME
with the TLS-ALPN check (it connects to the service's own port 443; the firewall
lets it reach the vault and nothing else).

The root key is on the YubiKeys (PIV slot 9c, PIN and touch) and in gopass
(`pki/bresilla/root-key`); it signed the intermediate once. Hive holds only the
intermediate's key and password. `services/ca/make-root.sh`
creates all of it in one go: run it on a machine with both YubiKeys, then commit
`shared/system/pki/` and update hive. The CA container exists only once those
certificates are in the repo.

Every machine trusts the root through `shared/system/pki.nix`: the system store,
and at each login the browsers' own databases (Chromium, its Flatpak, Firefox,
Zen). Phones take `shared/system/pki/bresilla-root.crt` by hand, as a CA
certificate in the user trust store.

Vaultwarden backs up its database every night inside the container; at 04:10
UTC hive copies it to nest's `/data/id/vault/<date>/` (30 days kept).

## Cloudflare tunnel

`services/tunnel/host.nix` runs the locally managed tunnel `hive-nix`; services add their
hostnames to its `ingress`: `git.bresilla.com` and `ssh-git.bresilla.com`
(gitea), `cache.bresilla.com` (the cache container), `s3.bresilla.com` (the s3
container). Machines reach gitea's SSH
through `cloudflared access ssh`, set in `shared/system/remote.nix`.

## Secrets and state outside this repository

| What | Where | Recreate |
| --- | --- | --- |
| Tunnel credentials | `/var/lib/cloudflared-hive-nix.json` (root, 0400) | `cloudflared tunnel token --cred-file <file> hive-nix` after `cloudflared tunnel login` |
| Tunnel `hive-nix` and the DNS records `git`, `ssh-git`, `cache`, `s3` | Cloudflare | `cloudflared tunnel create hive-nix`, then `cloudflared tunnel route dns hive-nix <name>.bresilla.com`; a new tunnel has a new ID for `tunnel.nix` and `gitea/default.nix` |
| Gitea database, accounts, secret keys | the container on hive; nightly copy on nest | see Gitea above |
| People, passkeys, groups and sign-in clients of id | Kanidm's database in the id container; nightly copy on nest | see id above; the sites' login secrets are remade by `oidc-secrets` |
| NetBird setup key, `ci` group and its policy (ci → hive TCP 8080) | NetBird dashboard | recreate; the key is ephemeral and reusable |
| Attic token signing key | `/var/lib/atticd.env` in the cache container (atticd, 0400); nightly copy on nest | `printf 'ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64="%s"\n' "$(openssl genrsa -traditional 4096 \| base64 -w0)"`; every issued token then stops working |
| Pins API token | `/var/lib/cache-ui.env` in the cache container (atticd, 0400) | `printf 'CACHE_PIN_TOKEN=%s\n' "$(head -c 32 /dev/urandom \| base64 \| tr -d '/+=')"`, then update `PIN_TOKEN` in GitHub |
| Caches `bresilla`, `packages`, `kernels` and their signing keys | `server.db` in the cache container; nightly copy on nest | `attic cache create home:<name>` and `attic cache configure home:<name> --public`; a new cache has a new public key, so `shared/caches.json` and `flake.nix` need it too |
| s3 root key | `/var/lib/s3/root.env` in the s3 container (root, 0600) | delete it and restart `s3-root` and `rustfs`; a new one is made |
| bresilla root CA key | PIV slot 9c on both YubiKeys; `pki/bresilla/root-key` in gopass | only from gopass (`ykman piv keys import 9c` onto a new key); losing every copy means a new root, trusted again everywhere |
| Intermediate CA key and password | `/var/lib/step-ca-secrets/{intermediate_key,password}` in the ca container (root, 0600); password also in gopass | sign a new intermediate with the root (`step certificate create … --profile intermediate-ca --ca … --ca-key …`), commit its certificate, install key and password there |
| Vault items, accounts, keys | Vaultwarden's database in the vault container; nightly copy on nest | restore `db.sqlite3` and the `rsa_key*` files into `/var/lib/vaultwarden` with `vaultwarden` stopped |
| GitHub secrets `ATTIC_TOKEN`, `PIN_TOKEN`, `NETBIRD_SETUP_KEY` | bresilla/nixos, and the termworks, paneworks and ai-nerv orgs | token: `atticd-atticadm make-token --sub github-ci --validity 1y --pull '*' --push '*'` inside the container; set with `gh secret set` (`--org <org> --visibility all` for the orgs) |

## Radicle

`services/gitea/radicle/` puts a Radicle node beside gitea, enabled
with `bresilla.services.gitea.radicle`. Every 30 seconds `radicle-sync` reads
gitea's database and publishes each public repository (not private, not a mirror,
not empty, public owner, no `no-radicle` topic) with `rad init`, then mirrors its
branches and tags and follows its name, description and default branch. Gitea
stays the source of truth. A repository that turns private, gets the topic or is
deleted is unseeded; copies already on the network stay there. The clone panel
gets a Radicle tab with `rad clone rad:…`, read from `/-/radicle/<owner>/<repo>.json`.

Radicle allows one key per node. The main node's key is bresilla's
(`/var/lib/radicle-identity/radicle` in the container, imported from
`identityFrom`, earlier keys in `retired/`): it signs his repositories, those of
organisations whose owners team he is in, and what he does in gitea. A user listed
in `users` gets a node of their own, `radicle-node@<user>` with its home in
`/var/lib/radicle-users/<user>`. Repositories of anyone else are not published,
and nothing other users do in gitea goes to Radicle. The nodes open outbound
connections only and seed nothing but what the sync publishes; the sync's state
(Radicle IDs and nodes per gitea repository id) is `/var/lib/radicle-sync`.

`services/gitea/host.nix` enables it for git.bresilla.com. The nightly backup keeps the
keys encrypted to the YubiKeys: each node's key is the delegate of its
repositories. With the recovery key as a second delegate, identity changes (name,
description, default branch) need its vote: the sync proposes once and fails until
`rad id accept <revision> --repo <rid>` is run on a node holding the recovery key.

## Git mirror

`services/gitea/mirror/` mirrors public repositories to other git
hosts over SSH (`bresilla.services.gitea.mirror`). The key is ECDSA P-256 made in
hive's TPM (`/var/lib/git-mirror/id_ecdsa.tpm`, made with `ssh-tpm-keygen`), served
by `git-mirror-agent` (ssh-tpm-agent) on hive; the gitea container gets only its
socket directory `/run/git-mirror-agent`, usable by the container's
`git-mirror-agent` group (gid 3011). Inside, `git-mirror` runs every 30 seconds:
per link push, pull or two-way, fast-forward only, a branch changed on both sides
is left alone and shown as diverged, and push or two-way first refuse when the
remote has anything gitea lacks. Private repositories are never mirrored. Links,
owner namespaces and trusted host keys are in `/var/lib/git-mirror-config`, state
and work repositories in `/var/lib/git-mirror`; the repository, user and
organisation settings pages edit them. GitHub's host keys are pinned in the
module. `sudo hive-check` reports the agent, its key and failing links.
