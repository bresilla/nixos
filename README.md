# NixOS config

`#laptop` is the laptop configuration; `#server` is the server configuration.
Both target x86_64 machines booting with UEFI.

From a NixOS live environment, launch the shell installer:

```sh
curl -fsSL https://nix.bresilla.dev | bash
```

It asks you to create a machine-specific, self-contained `disko.nix` and provide
its path, then asks for your username. It confirms disk erasure, runs Disko and
`nixos-install`, and asks for the root and account passwords in the terminal.
Your layout, username (in `user.nix`), and this config are saved to `/etc/nixos`.
From a checkout, use
`./install.sh laptop /path/to/disko.nix` (or `server`).

For manual installation, create `disko.nix` in this checkout with your machine's
disk devices and filesystem layout, including `/` and a UEFI partition at `/boot`.
Also create `user.nix` with your chosen username:

```nix
{ bresilla.user.name = "yourname"; }
```

Both files are gitignored and must exist before checking or rebuilding the flake.
From a NixOS live environment (Disko erases the defined disks):

```sh
sudo nix run github:nix-community/disko -- --mode destroy,format,mount ./disko.nix
sudo nixos-install --flake path:.#laptop
sudo nixos-enter --root /mnt -- passwd yourname
```

Use `#server` instead for a server. Keep this checkout on the installed machine
for subsequent rebuilds:

```sh
nix flake check --no-build path:.
sudo nixos-rebuild switch --flake path:.#laptop
```

Shared settings live in `configuration.nix` and `modules/`.
