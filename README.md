# NixOS Install

This repo builds and installs the generated laptop/server NixOS systems, then leaves a working copy of the config at `/etc/nixos` on the installed machine.

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

The installer writes generated disk, host, and user files before install. After install, `/etc/nixos/specific/configuration.nix` is the local host override file. It is imported by the flake but ignored by git.

Detailed docs:

- [Install flow](docs/install.md)
- [Post-install workflow](docs/post-install.md)
- [`nx` command](docs/nx.md)
- [Repository layout](docs/layout.md)
- [Secrets](docs/secrets.md)
- [Troubleshooting](docs/troubleshooting.md)

