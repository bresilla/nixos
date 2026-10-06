# NixOS

Software profiles live in `shared/`; device hardware and disk layouts live in
`devices/`. Root `install.sh` and `discio.sh` remain the entry points.

```text
shared/
  profiles/          # laptop, server, phone, iot
  programms/         # shared applications
  services/
  installer/         # Oslo installer and disk designer
devices/
  t480/              # installed ThinkPad: hardware + actual Disko layout
  fp6/               # Fairphone 6 kernel, firmware, storage and boot images
    development/     # build and inspection shell
```

| Profile | Purpose |
| --- | --- |
| `#laptop` | Desktop, shared tools, biometrics and ModemManager |
| `#server` | Shared tools and server services |
| `#phone` | Shared apps, dotfiles, SSH and ModemManager; console first |
| `#iot` | Shared apps, dotfiles and SSH for ARM64 boards |

Saved device targets are `#t480` and `#fp6`. By default `#laptop` uses `t480`
and `#phone` uses `fp6`; `machine.nix` selects another device for a profile.
Pi 5, Pi 4 and Radxa can share `#iot`, but each needs its own hardware, kernel,
firmware and boot configuration. No board-specific support is assumed.

## Install or update

```sh
curl -fsSL https://nix.bresilla.dev | bash
```

The Bash bootstrap loads current normal Oslo from the signed Termworks cache on
x86_64 or ARM64. The menu offers:

- **Update this machine:** keep the account and selected device, refresh inputs,
  and build on that machine.
- **Install:** choose a saved device or **New device**. A new device gets a profile,
  an existing hardware file or UEFI hardware detection, and an existing or newly
  designed Disko layout, saved under `devices/<name>/`.

Disko installation requires a suitable live environment. Before erasure, the
installer shows the actual disks and requires their paths to be typed. It asks
for the username, dotfiles repository and passwords. Selecting the FP6 shows its
separate image-installation instructions; Android storage is never passed to
ordinary Disko. See [the FP6 guide](devices/fp6/README.md).

```sh
./install.sh laptop /path/to/disko.nix
./discio.sh
./discio.sh --remote nixos@192.168.1.135 ./new-disko.nix
```

The designer supports multiple disks, LVM, Btrfs/ext4, swap, LUKS and custom mounts.
It reads disk information and saves Nix; it does not format disks.

## Machine-local settings

These root files are gitignored and kept in `/etc/nixos`:

```nix
# machine.nix
{ profile = "phone"; device = "fp6"; }

# user.nix
{ bresilla.user.name = "yourname"; }
```

`dotfiles.nix` records the chosen public Git URL, revision and hash. The installer
shows a grey URL suggestion that Right Arrow fills; the repository must contain
`nix/home.nix` and `.config`. Home Manager links all its configured dotfiles into
an editable `~/.dot` checkout and backs up conflicts. Clean checkouts fast-forward;
local edits and commits are preserved. Portable non-Nix usage remains available.

Old installations with root-level `disko.nix`/`hardware.nix` remain supported.
The installed T480 layout and initial standalone FP6 can migrate through Update.
Custom device folders stay in `/etc/nixos`; commit them when you want them offered
on other machines.

Manual updates for ordinary devices, from `/etc/nixos`:

```sh
sudo nix flake update --refresh --flake path:.
sudo nixos-rebuild switch --flake path:.#laptop
```

Use the machine's profile. The FP6 also needs its matching boot image written;
the online updater performs that step. Inputs use no fixed version tags. Each
update generates a fresh lock for that run instead of selecting old versions.

All profiles include Termworks apps, Goku, Morf and its Lua library, using the
Termworks and Paneworks caches. Oslo is the normal user's shell; root retains its
default shell. Morf desktop services and biometrics belong to the laptop profile.

`nixosModules.default` and `nixosModules.{laptop,server,phone,iot}` expose the shared
software for other flakes without importing a particular device's hardware.
