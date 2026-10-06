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
| `#phone` | Same graphical base as laptop, with separate phone-specific settings |
| `#iot` | Shared apps, dotfiles and SSH for ARM64 boards |

Saved device targets are `#t480` and `#fp6`. By default `#laptop` uses `t480`
and `#phone` uses `fp6`; `machine.nix` selects another device for a profile.
Pi 5, Pi 4 and Radxa can share `#iot`, but each needs its own hardware, kernel,
firmware and boot configuration. No board-specific support is assumed.

## Update an installed machine

`/etc/nixos` is the complete checkout, including that machine's settings. Run on
the machine being updated:

```sh
cd /etc/nixos
sudo git pull
sudo ./install.sh
```

Or fetch the online updater:

```sh
curl -fsSL https://nix.bresilla.dev | bash
```

Both routes automatically update an installed machine. Its saved device, user
and dotfiles URL are reused. The chosen dotfiles repository and shared software
inputs are refreshed without asking setup questions again. A missing dotfiles
setting is requested once, including when migrating the initial minimal FP6.

The FP6 keeps its installed kernel, modules and firmware. The updater repackages
its boot image for the new system without compiling a kernel. FP6 source inputs
live in an independent development flake; ordinary updates do not fetch them.

## Install a new machine

On a live system the same command starts installation. `./install.sh --install`
also explicitly selects installation. Choose a saved device or **New device**.
A new device gets a profile, an existing hardware file or UEFI hardware detection,
and an existing or newly designed Disko layout, saved under `devices/<name>/`.

The Bash bootstrap loads current normal Oslo from the signed Termworks cache on
x86_64 or ARM64.

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
The installed T480 layout and initial standalone FP6 migrate automatically.
Custom device folders stay in `/etc/nixos`; commit them when you want them offered
on other machines.

The FP6 also keeps `boot-hardware.json` here, recording its existing kernel,
modules, firmware and kernel configuration. It is machine-local and gitignored.
Software inputs use no fixed version tags; each update resolves current revisions.

All profiles include Termworks apps, Goku, Morf and its Lua library. Every installer
run resolves their latest named Termworks and Paneworks Cachix entries and verifies
the downloaded binaries. `cache-binaries.json` saves that machine's resolved paths
and is gitignored; no release versions are hardcoded. A missing cached binary
stops the update instead of silently compiling another Git revision.
Oslo is the normal user's shell; root retains its
default shell. Laptop and phone share Hyprland, Morf login/shell/lockscreen,
audio, Bluetooth, Flatpak and desktop utilities through `shared/profiles/graphical.nix`.
Their own profile files hold device-type differences. Fingerprint and YubiKey
services remain laptop features; Gaze is not included.

`nixosModules.default` and `nixosModules.{laptop,server,phone,iot}` expose the shared
software for other flakes without importing a particular device's hardware.
