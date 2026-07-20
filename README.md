# NixOS Install

This repo builds and installs the laptop/server NixOS systems, then leaves a working copy of the config at `/etc/nixos` on the installed machine.

Installation is driven by [nox](https://github.com/bresilla/nox), the installer TUI living in its own repository. nox emits exactly one artifact — a [LIS](https://github.com/onix-os/lis) document at `host/generated/system.lis.json` — and this repo translates it to Nix at evaluation time: `host/lis/` derives the disko layout, users, secrets policy, and host settings straight from the document.

Quick entry points:

```bash
./install.sh
nx check
nx generate
nx edit
nx secret --help
```

After installation, the normal system workflow is:

```bash
cd /etc/nixos
nx edit package essential
nx edit specific
nx check
nx generate
```

The installer writes only `host/generated/system.lis.json`; everything Nix derives from it lives in `host/lis/`. After install, `/etc/nixos/specific/configuration.nix` is the local host override file. It is imported by the flake but ignored by git.

Detailed docs:

- [Install flow](docs/install.md)
- [Post-install workflow](docs/post-install.md)
- [`nx` command](docs/nx.md)
- [Repository layout](docs/layout.md)
- [Secrets](docs/secrets.md)
- [Troubleshooting](docs/troubleshooting.md)

