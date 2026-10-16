# NixOS

Software profiles live in `shared/`; device hardware and disk layouts live in
`devices/`; dotfiles live in `configs/`. Root `install.sh` and `discio.sh` remain
the entry points.

```text
shared/
  profiles/          # device-type profiles: which features each role gets
    shared.nix       # common settings selected by laptop and phone
    laptop/
    workstation/     # laptop, always plugged in, serving its desktop over RDP
    phone/           # also the phone's window gestures
    server/
    iot/
  system/            # machine settings
    default.nix      # Nix, boot, locale, security and maintenance defaults
    hardware.nix     # reusable hardware support, power and peripherals
    udev.nix
    desktop.nix      # compositor, audio and desktop session
    network.nix      # NetworkManager, ModemManager, radios, firewall and SSH
    dns.nix          # resolver settings
    hosts.nix
  services/          # daemons
    network/         # vpn.nix (NetBird, Tailscale, WireGuard, Mullvad), wireproxy, blocky, privaxy, canup
    desktop/         # per-login daemons: spotifyd, mpris, yubikey-agent, drop, greenclip
  users/             # accounts and Home Manager
  programs/          # package collections and application installers
  installer/         # Oslo installer, disk designer and cache handling
devices/
  shared/            # reusable boot settings
  t480/              # installed ThinkPad: hardware + actual Disko layout
  xps/               # Dell XPS 15 9510: spare SSD layout and hardware
  fp6/               # Fairphone 6 kernel, firmware, storage and boot images
    development/     # build and inspection shell
    scripts/         # device runtime helpers
configs/
  assets/            # ~/.config/<app> folders, linked from ~/.dot
  home/              # files linked into ~
  run_me.sh          # links them outside NixOS
tests/               # installer and device checks
```

Morf owns its desktop, greeter, lockscreen, scaling, wallpaper and phone controls
in [its upstream NixOS module](https://github.com/paneworks/morf/tree/develop/nix).
This repository imports that module and sets `programs.morf` preferences in the
profiles and device configurations. Morf code, compatibility patches and tests
belong upstream. Device-specific runtime helpers stay with their hardware.

The installer offers optional pattern enrollment after setting the password.
Morf handles validation and private credential storage. Its phone module owns
native gestures and double-tap/power-key wake; scrolling, scrollbars and the
phone bar are implemented in Morf itself. Desktop profiles use Morf's packaged
shell, lockscreen and greeter so older dotfiles do not hide release fixes.

Profiles select features; the other shared modules implement them. Each folder in
`profiles/` is a public device-type profile, and `profiles/shared.nix` is the part
laptop and phone have in common. `devices/` holds physical wiring, disk layouts and
hardware-specific fixes; device-specific modem settings live in `modem.nix`.

NetworkManager manages connections and ModemManager controls cellular hardware.
Their common setup belongs together in `system/network.nix`; the desktop
subprofile selects cellular support for laptop and phone.

| Profile | Purpose |
| --- | --- |
| `#laptop` | Desktop, shared tools, biometrics and ModemManager |
| `#server` | Shared tools and server services |
| `#phone` | Same graphical base as laptop, with separate phone-specific settings |
| `#iot` | Shared apps, dotfiles and SSH for ARM64 boards |

Saved device targets are `#t480`, `#xps` and `#fp6`. By default `#laptop` uses `t480`
and `#phone` uses `fp6`; `machine.nix` selects another device for a profile.
Pi 5, Pi 4 and Radxa can share `#iot`, but each needs its own hardware, kernel,
firmware and boot configuration. No board-specific support is assumed.

## Update an installed machine

`/etc/nixos` holds only the machine's identity; the code lives anywhere. Update
from GitHub's main without a password:

```sh
sudo nixos-update
```

Or build a checkout, local edits included:

```sh
~/nixos/install.sh
```

Or fetch the online updater:

```sh
curl -fsSL https://nix.bresilla.dev | bash
```

All routes automatically update an installed machine. An older full checkout in
`/etc/nixos` is pulled once, then moved to `/etc/nixos.old-checkout`. The saved device
and user are reused, and shared software inputs are refreshed without asking setup
questions again.

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
for the username and passwords. Selecting the FP6 shows its
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

These root files are gitignored and are the only files kept in `/etc/nixos`:

```nix
# machine.nix
{ profile = "phone"; device = "fp6"; }

# user.nix
{ bresilla.user.name = "yourname"; }
```

## Dotfiles

The dotfiles live in this repository under `configs/`: `assets/<app>` holds an
application's `~/.config/<app>` folder and `home/` holds files for `~`. Every
machine keeps this repository cloned in `~/.dot`; the installer clones it, or
fast-forwards it while saving and restoring local edits, and moves anything else
found there to `~/.dot.old-dotfiles`. Divergent commits leave the checkout as it is.

On NixOS, Home Manager links each folder into `~/.dot`, so edits apply at once.
A `configs/<app>.nix` module may take an application over; its `assets/<app>`
folder is then deleted. Elsewhere, `install.sh` (or the curl command) links the
same folders through `configs/run_me.sh`, which needs only Git and curl.

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
audio, Bluetooth, Flatpak and desktop utilities through `shared/profiles/shared.nix`.
Their own profile files hold device-type differences. Fingerprint and YubiKey
services remain laptop features; Gaze is not included. A workstation is a laptop
without battery tuning that starts its remote Hyprland session over RDP at boot.

Source compilation requires two separate explicit confirmations before it starts. Prefer
available binary caches; inspect an update's build plan before applying it.
Nix evaluation and generating configuration files do not compile applications.

Graphical profiles run the Morf greeter in a dedicated, quiet Hyprland session.
The desktop also hides Hyprland's logo, splash and notices, with startup output
kept in the journal. Its system entry point loads the user's Hyprland dotfiles
before applying these shared settings. Phone greeter idle/power controls stay
in the phone profile.

`nixosModules.default` and `nixosModules.{laptop,server,phone,iot}` expose the shared
software for other flakes without importing a particular device's hardware.

## Checks

Run from the repository root; these tests do not install or format anything:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests
oslo --norc tests/installer.lua "$PWD"
```
