# Install Flow

`install.sh` is the destructive installer entry point. It builds a generated laptop or server config, runs Disko/nixos-anywhere or local secret drop, copies this repo into the installed system, optionally runs dotfiles, then reboots the remote target.

## Entry Points

Interactive install:

```bash
./install.sh
```

Remote install:

```bash
./install.sh remote laptop novo nixos@10.10.10.7
./install.sh remote server novo nixos@10.10.10.7
```

Preflight only:

```bash
./install.sh preflight laptop novo nixos@10.10.10.7
```

Local mounted install finalization:

```bash
./install.sh local novo /mnt
```

## What The Installer Generates

The installer writes files under `generated/`:

- `generated/disko.nix`: Disko layout selected by the wizard.
- `generated/host.nix`: hostname and generated hardware defaults.
- `generated/user.nix`: primary user and optional hashed password path.
- `generated/install-summary.txt`: human-readable install summary.

Those files are ignored by git because they are generated per install run.

## What Gets Installed To The Target

After the generated system is installed, the installer copies this repo into:

```text
/mnt/etc/nixos
```

On the installed system that becomes:

```text
/etc/nixos
```

The copied repo gets:

```text
/etc/nixos/.nixos-role
/etc/nixos/specific/configuration.nix
```

`.nixos-role` contains `laptop` or `server`. `specific/configuration.nix` is created as an empty local override file.

## Ownership

The installer creates a system group named `corner` through the NixOS config. The default install user is added to that group.

The copied config repo is owned as:

```text
root:corner
```

Directories are setgid and group-writable, so members of `corner` can edit `/etc/nixos` after login.

After the first boot, log out and log back in if group membership is not visible yet.

## Remote Install Order

The remote install path does this:

1. Decrypts the shared system key and required secrets.
2. Checks the generated NixOS config.
3. Confirms the destructive disk wipe.
4. Runs Disko and installs NixOS through `nixos-anywhere`.
5. Mounts the installed system at `/mnt` using the generated mount script.
6. Copies this repo into `/mnt/etc/nixos`.
7. Writes `.nixos-role`.
8. Creates `specific/configuration.nix`.
9. Chowns `/mnt/etc/nixos` to `root:corner`.
10. Optionally runs dotfiles inside the installed system.
11. Reboots the target.

## Safety Notes

The remote Disko path wipes selected disks. Treat every remote install confirmation as destructive.

Run preflight before a real install when changing installer code:

```bash
./install.sh preflight laptop novo nixos@10.10.10.7
```

