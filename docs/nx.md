# nx Command

`nx` is the local interface for this repo after install. It is installed system-wide as a small wrapper that executes:

```text
/etc/nixos/nx
```

## Top-Level Commands

Install:

```bash
nx install
```

This runs `/etc/nixos/install.sh`.

Check:

```bash
nx check
nx check --role laptop
nx check --role server
```

This runs `generate.sh --check-only`.

Generate:

```bash
nx generate
nx generate --role laptop
nx generate --role server
```

This runs `sudo nixos-rebuild switch` against the generated flake output for the selected role.

Status:

```bash
nx status
```

This shows `git status --short` for `/etc/nixos`.

Secrets:

```bash
nx secret secrets/system.yaml
nx secret secrets/common/hosts
nx secret --decrypt secrets/common/github.yaml
```

This runs `sops` with:

```bash
SOPS_AGE_KEY_CMD='age-plugin-yubikey --identity'
```

## Editing Commands

Open a picker:

```bash
nx edit
```

Edit package groups:

```bash
nx edit package essential
nx edit package system
nx edit package desktop
nx edit package flatpak
nx edit package appimage
```

Edit services:

```bash
nx edit service resolver
nx edit service private-hosts
nx edit service netbird
nx edit service tailscale
nx edit service vpn-clients
nx edit service wireguard
nx edit service wur
nx edit service socketcan
```

Edit profiles:

```bash
nx edit profile laptop
nx edit profile server
```

Edit other system files:

```bash
nx edit specific
nx edit accounts
nx edit features
nx edit common
nx edit secrets
nx edit flake
```

Edit current user's local placeholder config:

```bash
nx edit user
```

This creates and opens:

```text
~/.nix/configuration.nix
```

## Editor Selection

`nx edit` uses:

1. `$EDITOR`
2. `$VISUAL`
3. `nvim`
4. `vi`

## Gum

If `gum` is installed and the command is running in a TTY, `nx edit` uses a picker when a target is missing. If `gum` is not available, it falls back to the first valid choice.

