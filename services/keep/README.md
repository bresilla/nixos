# Secrets kept for a new server

Each service lists the secrets only its server holds in `bresilla.server.keep`
(its `host.nix`); `default.nix` here adds the machine's SSH host keys. Daily and at
boot, every set that changed is packed, encrypted to the YubiKeys
(`bresilla.server.recipients`, the same as gopass) and left in
`/var/lib/server-keep/<set>.age`. Into gopass, from the laptop:

```sh
bash services/keep/to-gopass.sh hive
```

which commits them as `services/hive/keep/<set>`. Databases are not here: they go to
nest nightly with each service's own backup.

| Set | Holds |
|---|---|
| `ssh` | the server's SSH host keys |
| `tunnel` | the Cloudflare tunnel credentials |
| `cache` | the CI WireGuard key, Attic's signing secret, the cache page's secret |
| `logins` | every site's login secret on id.bresilla.com |
| `ci` | CI's cache and pin tokens, its token secret |
| `gitea` | gitea's own keys and config, the mirror bot's token, the Radicle identity |
| `vault` | the vault's signing key |
| `s3` | RustFS's admin key |

The CA's secrets are in gopass already (`pki/bresilla`), innernet's in
`services/hive/innernet/` (services/net/README.md). The git mirror's key lives in the
machine's TPM and never leaves it: a new machine makes its own, added to GitHub once.

## Restoring on a new server

Before its services first start, as root, each set straight back where it was:

```sh
gopass show -o services/hive/keep/<set> | base64 -d | sudo tar -C / -xpf - --numeric-owner
```

Then start the services; restore their databases from nest as each service's
README says.
