# Repository Layout

This repo is a reusable NixOS system config plus installer.

## Important Files

```text
flake.nix
install.sh
generate.sh
nx
scripts/check.sh
```

`flake.nix` defines:

```text
nixosConfigurations.install-laptop-generated
nixosConfigurations.install-server-generated
```

`install.sh` handles interactive install, remote install, local finalization, secret handling, Disko generation, repo copy, dotfiles, and reboot.

`generate.sh` is the post-install apply/check script.

`nx` is the user-facing command wrapper.

`scripts/check.sh` runs syntax, Nix parse, NixOS eval, and whitespace checks.

## Modules

Common system base:

```text
modules/common.nix
modules/features.nix
modules/accounts.nix
modules/secrets.nix
```

Profiles:

```text
modules/profiles/laptop.nix
modules/profiles/server.nix
```

Packages:

```text
modules/programms/essential.nix
modules/programms/system.nix
modules/programms/desktop.nix
modules/programms/flatpak.nix
modules/programms/appimage.nix
```

Services:

```text
modules/services/resolver.nix
modules/services/private-hosts.nix
modules/services/netbird.nix
modules/services/tailscale.nix
modules/services/vpn-clients.nix
modules/services/wireguard.nix
modules/services/wur.nix
modules/services/socketcan.nix
```

## Generated Files

`generated/` is ignored by git.

Expected files:

```text
generated/disko.nix
generated/host.nix
generated/user.nix
generated/install-summary.txt
```

These are created by the installer and imported by the flake if they exist.

## Local Host Overrides

`specific/` is ignored by git.

Expected file:

```text
specific/configuration.nix
```

This file is imported after the generated host config and profiles. Use it for host-local overrides.

## Role File

`.nixos-role` is ignored by git.

It contains:

```text
laptop
```

or:

```text
server
```

`generate.sh` uses it when no `--role` is passed.

## Import Order

The generated flake output imports modules in this order:

1. Disko and sops-nix modules.
2. Common/account/feature/secret modules.
3. Package modules.
4. Service modules.
5. Selected profile.
6. Generated host file.
7. Local `specific/configuration.nix`.
8. Generated Disko file.

Because `specific/configuration.nix` comes late, it can override most general defaults. Generated files use `lib.mkDefault` where practical so tracked modules and local overrides can win.

