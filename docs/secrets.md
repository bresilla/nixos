# Secrets

Secrets are managed with `sops-nix`, `sops`, and a YubiKey age identity.

## Files

Encrypted key:

```text
secrets/key.txt
```

Encrypted shared system secrets:

```text
secrets/system.yaml
```

Encrypted common secrets:

```text
secrets/common/github.yaml
secrets/common/hosts
```

SOPS config:

```text
.sops.yaml
```

Nix module:

```text
modules/secrets.nix
```

## Editing Secrets

Use:

```bash
nx secret secrets/system.yaml
nx secret secrets/common/github.yaml
nx secret secrets/common/hosts
```

Decrypt to stdout:

```bash
nx secret --decrypt secrets/system.yaml
```

`nx secret` sets:

```bash
SOPS_AGE_KEY_CMD='age-plugin-yubikey --identity'
```

It also checks that:

- `sops` exists
- `age-plugin-yubikey` exists
- `pcscd` is running
- `$EDITOR` exists when editing

## Installer Secret Handling

The installer decrypts the shared system key and required install secrets once per run when possible.

Temporary decrypted data is kept under `/dev/shm` when available:

```text
/dev/shm/nixos-install-system-key.<pid>
/dev/shm/nixos-install-secrets.<pid>
```

Those paths are cleaned up on exit.

For install, the decrypted age key is copied into the target as:

```text
/var/lib/sops-nix/key.txt
```

The generated system config points sops-nix at that key.

## GitHub Token Use During Install

The installer decrypts the GitHub token secret and passes it to the installed-system chroot as a temporary file for root `bin ensure`. If dotfiles are enabled, the same temporary token is also available to the dotfiles run. The temp file is removed on exit.

## Local Age Key Instead of a YubiKey

The Rust installer (`nx-rs`) can decrypt secrets with a plaintext age identity
file instead of the YubiKey. Point it at the file with either:

```bash
nx-rs remote-install-exec --age-key-file <path> ...
export NX_AGE_KEY_FILE=<path>   # honored by all install paths, including the TUI
```

The file is used both as the shared system key placed at
`/var/lib/sops-nix/key.txt` and as the sops age key that decrypts the GitHub
token. Without either, it falls back to the YubiKey (`install.sh key-check`).

## Self-Contained Test Secrets

For testing on a disposable target without a YubiKey, generate a throwaway
fixture:

```bash
nix-shell -p age sops --run scripts/setup-test-secrets.sh
```

This writes a gitignored `secrets-test/` containing a fresh age key
(`secrets-test/key.txt`) and dummy secrets encrypted to it for every key the
config expects. When `secrets-test/` exists:

- the transferred flake source overlays `secrets-test/` onto `secrets/`, so the
  target and its sops-nix config use the test secrets (the real `secrets/` and
  the plaintext key are never shipped);
- `nx-rs` decrypts the GitHub token from `secrets-test/`;
- `run_me.sh` uses `secrets-test/key.txt` automatically.

Nothing here decrypts or modifies the real secrets.

## Setting the User Password

By default the Rust installer leaves the primary user without a password
(key-only login, no working `sudo`). To set one, pass `--password <plaintext>`
(hashed with `mkpasswd -m yescrypt`) or `--password-hash-file <path>` (a
pre-computed yescrypt hash) to `remote-install-exec` / `local-install-exec`, or
set `NX_PASSWORD` for `run_me.sh`. The hash is written to
`/var/lib/nixos-install/user-password.hash` on the target before `nixos-install`,
and `generated/user.nix` points `bresilla.user.hashedPasswordFile` at it.
Without any of these, the account stays key-only as before.
