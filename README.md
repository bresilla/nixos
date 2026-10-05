# NixOS config

`#laptop` is the laptop configuration; `#server` is the server configuration.
Both target x86_64 machines booting with UEFI.

From a NixOS live environment, launch the installer:

```sh
curl -fsSL https://nix.bresilla.dev | bash
```

The Bash bootstrap loads the pinned normal Oslo package from the signed
`termworks` Cachix cache, then runs `install.lua`. Oslo asks you to choose an existing Disko file
or create one with `discio.sh`. The designer supports multiple disks, plain
partitions or pooled/separate LVM groups, Btrfs/ext4, swap, optional LUKS, and
custom mounts and subvolumes. Edit volumes, review capacity bars and preview Nix
before saving your machine-specific `disko.nix`. It also asks for your username.
The installer confirms disk erasure, runs Disko and
`nixos-install`, and asks for the root and account passwords in the terminal.
Your layout, username (in `user.nix`), and this config are saved to `/etc/nixos`.
From a checkout, use
`./install.sh laptop /path/to/disko.nix` (or `server`).

To design a layout independently (this only reads disk information and saves a file):

```sh
./discio.sh
./discio.sh --remote nixos@10.10.10.135 ./laptop-disko.nix
```

Sizes accept units such as `32G` or `1.5GiB`, percentages such as `25%`, and
`100%` for the remaining space. Percentages are resolved to fixed sizes in the
saved layout. Mounted disks are hidden by default; choose "All disks" to design
a layout for an existing system. LUKS passwords are asked by Disko when installing.

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

The Termworks tools Oslo, Hexe (multiplexer), Drop, Pixy, Lule, Geto, Trek, and Wing
are installed on both profiles. Oslo is the chosen user's login shell; root keeps
its default shell.
Morf's engine and matching Lua library are also installed on both profiles.
The laptop uses Caelestia with the Tsugumori theme for its greetd/Cage login screen,
desktop shell, and `morf lock`. Shared configuration and fonts live under
`/etc/xdg/morf/`, with Caelestia as the system default. The Hyprland UWSM session
starts Morf's user service after login. User dotfiles can override the defaults.
Nix uses `termworks.cachix.org` and `paneworks.cachix.org` alongside the official
NixOS cache. The external inputs keep their upstream dependencies. Their URLs
track the repositories without fixed versions; refresh them with
`nix flake update oslo hexe drop pixy lule geto trek wing morf`.
Add future tools to the `termworks` group in `flake.nix`;
`modules/programms/termworks.nix` installs their default packages.

Shared settings live in `configuration.nix` and `modules/`.
