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
