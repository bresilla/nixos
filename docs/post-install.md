# Post-Install Workflow

After install, the machine should boot into the generated NixOS config and have this repo at:

```text
/etc/nixos
```

Use that directory for system changes:

```bash
cd /etc/nixos
```

## Normal Change Loop

1. Edit a module.
2. Check the config.
3. Apply it.

```bash
$EDITOR host/modules/programms/essential.nix
nix flake check ./host
sudo nixos-rebuild switch --flake ./host#install-<role>-generated
```

`nixos-rebuild switch` applies the flake output for the machine's role:

```bash
sudo nixos-rebuild switch --flake path:/etc/nixos#install-<role>-generated
```

The `path:` prefix matters because generated and local files are gitignored but still must be seen by Nix.

## Where To Put Changes

Tracked general system changes go in the repo modules:

```text
modules/programms/*.nix
modules/services/*.nix
modules/profiles/*.nix
modules/features.nix
modules/common.nix
modules/accounts.nix
modules/secrets.nix
```

Host-local changes go in:

```text
specific/configuration.nix
```

That file is imported by the flake and ignored by git. It is meant for local overrides you do not want tracked.

User-local future config goes in:

```text
~/.nix/configuration.nix
```

Open it with:

```bash
$EDITOR host/generated/system.lis.json   # users live in the LIS document
```

At the moment this file is just a local user config placeholder. It is not the main system configuration.

## Adding Packages

Open the package group:

```bash
$EDITOR host/modules/programms/essential.nix
$EDITOR host/modules/programms/system.nix
$EDITOR host/modules/programms/desktop.nix
edit package bin
edit package flatpak
edit package appimage
```

Then check and apply:

```bash
check
generate
```

## Adding Services

Open the service module:

```bash
edit service resolver
edit service tailscale
edit service wireguard
```

Then:

```bash
check
generate
```

## Switching Role

The installed role lives in:

```text
/etc/nixos/.nixos-role
```

It should contain:

```text
laptop
```

or:

```text
server
```

You can override the role for one command:

```bash
check --role server
generate --role server
```

Changing the role permanently means editing `.nixos-role`.
