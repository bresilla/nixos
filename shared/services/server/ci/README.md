# Hive CI

The original Hive interface serves `build.bresilla.com` on loopback port 8091,
with Muros's API on port 8090 behind Caddy and the existing oauth2-proxy/Kanidm
login. The original markup, stylesheet, SVG, theme, routes and controls remain
in `hive-ui/`; `backend.py` connects them to Muros. Repositories and builder mappings live in
`/var/lib/murosd/server.db`; the service regenerates `/var/lib/murosd/machines`.
Builds are remote-only, with sandboxed evaluation inside the CI container. Root
`flake.nix` checks build automatically; optional `.muros.lua` overrides defaults
for subflakes, targets, conditions and cache settings. Repository TOML is not read.

Each repository has a **Rules** page for UI fallback configuration: branch/tag
include/exclude globs, changed-path filters, manual-build permission, flake/output
selection and cache/pinning. A default-branch `.muros.lua` overrides UI scheduling
settings; the exact build commit supplies its recipes. Tag-only mode builds a
matching tagged commit only after it belongs to an allowed branch. First-time tag
discovery selects the newest eligible tag rather than replaying all releases.
Build now respects branch/tag rules and bypasses path filters. Pins are opt-in;
use `{name}-{system}` to keep architecture outputs separate.

Repository rules introduce schema migration `m0012_repository_rules`. Rollback to
an older daemon requires restoring the matching database backup, not merely its
host generation. Guarded rule-release rollout snapshots live under
`/var/backups/muros-rules/`; both server and frontend databases are preserved.

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
Manage repositories and builders through the original Hive UI or Muros CLI; legacy JSON files
are retained only for rollback and are no longer configuration inputs.

The Hive frontend requires the local SQLite database. Its private
`/var/lib/muros-ui/frontend.db` preserves original build numbers, unassigned
systems and machine drafts. Unpinned drafts cannot build until the explicit
Fetch host key action pins a key. Secret settings update the credential files;
`muros-credentials.path` restarts Muros to load them. Settings retain their original
controls, with the service label updated to Muros. Form CSRF tokens and internal API sessions are not rendered as
visible controls.

The history restoration preserves all 14 original build numbers and 458
attribute records, and copies the 40 retained logs. Three revisions also built
under Muros share a canonical run; their original display snapshots survive
until an explicit restart/cancel action replaces that displayed result.
The migration preserves the database dump, old state and original host generation under
`/var/backups/muros-migration/` on Hive and inside CI. Restoring the previous host
generation restores the old service definitions; keep the old data until the
rollback window closes. The temporary sudoers mount must be revoked before a
NixOS activation rewrites `/etc/sudoers`.
