# Hive CI

Muros serves `build.bresilla.com` on loopback port 8090 behind Caddy and the
existing oauth2-proxy/Kanidm login. Repositories and builder mappings live in
`/var/lib/murosd/server.db`; the service regenerates `/var/lib/murosd/machines`.
Builds are remote-only, with sandboxed evaluation inside the CI container.

`muros-release.json` identifies the verified static package. The corresponding
`muros-x86_64-linux` pin is in the signed `packages` cache, which the normal
installer resolves and downloads. Change the package and module together after
testing a new release. No source-build fallback is enabled.

Runtime credentials are loaded by systemd, never copied into the Nix store:

- `/var/lib/ci/builder_ed25519`: existing builder identity.
- `/var/lib/ci/secrets/{attic-token,pin-token}`: cache publication credentials.
- `/var/lib/murosd-secrets/token-secret`: private random token-signing key.
- `/var/lib/oidc/proxy.env`: existing oauth2-proxy credentials.

For a fresh installation, provision those files before enabling the service.
The token-signing key must be at least 32 random bytes, root-owned and mode 0600;
its parent directory must be mode 0700. Existing migrations must preserve it.
Manage repositories and builders through the Muros UI or CLI; legacy JSON files
are retained only for rollback and are no longer configuration inputs.

Nixbot's PostgreSQL history is not imported into Muros. The migration preserves
the database dump, old state and original host generation under
`/var/backups/muros-migration/` on Hive and inside CI. Restoring the previous host
generation restores the old service definitions; keep the old data until the
rollback window closes. The temporary sudoers mount must be revoked before a
NixOS activation rewrites `/etc/sudoers`.
