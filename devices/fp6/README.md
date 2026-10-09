# Fairphone 6

This is the FP6 we boot-tested, not the FP5. It uses the Android bootloader and
a device-specific kernel. A PC live-USB Disko installation is not suitable.

- `default.nix`: device settings and USB/Wi-Fi networking.
- `hardware.nix`: reuse of the installed kernel/firmware, USB gadget and boot-image builder.
- `storage.nix`: nested 4096-byte-sector GPT inside Android `userdata`, root growth
  and the `FP6-BOOT` filesystem label. This uses systemd-repart, not Disko.
- `touchscreen.nix`: boot recovery for the ESWIN controller after display startup.
- `modem.nix`: modem services, with SIM initialization in `scripts/`.
- `development/`: a separate flake with kernel/firmware build recipes and tools.
- `update-boot.sh`: checked boot-image updates on the installed FP6 (slot A).

The shared `#phone` profile supplies applications and accounts. In the repository
checkout on this phone, `machine.nix` selects it:

```nix
{ profile = "phone"; device = "fp6"; }
```

Keep `user.nix` and the selected `dotfiles.nix` on the device. Neither contains a
plaintext password. SSH uses the account's authorized keys; change its password
interactively with `passwd`.

Morf's NixOS module installs pattern support. Run `sudo morf-pattern setup USER` after
setting the account password. The hidden, confirmed prompt validates adjacent
dots and stores a root-only salted hash on the device. This enrollment is shared
by greetd and the lock screen. Normal updates preserve it; neither the pattern
nor its hash goes into `user.nix` or a built image. The live-USB installer offers
the same step automatically after setting the password on desktop installations.

Morf's executable and Lua library use the named Paneworks cache entries. Its
upstream NixOS module supplies the graphical integration and complete fallback
theme. The desktop profile selects that packaged UI for shell, lock and greet.
`programs.morf.phone.enable` selects native gestures and double-tap or
power-key wake. Scrolling inertia, panel/workspace gestures, the phone scrollbar
and the hidden app list in the phone bar belong to Morf's implementation. This
device sets compositor scale and idle preferences; it carries no Morf patches,
copied source tree or source-build override.

Neither the account password nor the pattern is saved in this repository or
the Nix store. The pattern's salted hash stays under `/var/lib/morf/pattern`
with root-only access. Rebuilding preserves enrollment; after wiping userdata,
enroll again. Only enrolled users are offered a pattern by the greeter.

## Updating the installed phone

Run `curl -fsSL https://nix.bresilla.dev | bash` on the phone. Or use its checkout:

```sh
cd /etc/nixos
sudo git pull
sudo ./install.sh
```

Update is automatic. It reuses the account and saved dotfiles URL, resolves
current software inputs and applies the system. `boot-hardware.json` preserves
the installed kernel, modules, firmware and full kernel configuration. The first
update records these from the existing installation; subsequent updates keep them.
Optional `extraModules` entries in that snapshot retain separately built module
outputs for this exact kernel. `development/touchscreen.nix` builds only the
ESWIN touchscreen module against matching existing kernel headers; it does not
rebuild the kernel. New explicit kernel builds enable that driver directly.
The `fp6-touchscreen` service waits until the active Hyprland compositor reports
the phone display powered on, then rebinds this driver once. The boot framebuffer
can report an enabled panel before the compositor starts; resetting at that point
leaves the controller enumerated but producing no touches. This is a
device-specific workaround using the existing module.
The updater repackages and writes the boot image so it starts the new system.
It does not compile or update the kernel. A plain `nixos-rebuild switch` alone
does not update the Android boot partition.

For a first installation, explicitly build the hardware artifacts first:

```sh
nix flake update --flake path:./devices/fp6/development
nix build path:./devices/fp6/development#boot-hardware --out-link result-fp6-hardware
cp result-fp6-hardware boot-hardware.json
```

After supplying `user.nix` and `dotfiles.nix`, build `fp6-userdata` and `fp6-boot`, then use Fastboot to
flash `userdata` and `boot_a`, and erase `dtbo_a`. This replaces phone data and
requires the unlocked bootloader, verified backups and slot A selected. Check the
device identity before any flash. Never run a generic Disko erase on the phone.

## Development and recovery

From the repository root, `nix develop .#fp6` opens the tool environment.
`nix build path:./devices/fp6/development#kernel` explicitly compiles a kernel,
cross-compiling on x86_64 or compiling natively on ARM64. Full x86-hosted hardware
and phone image builds also need an ARM64 builder for firmware and userspace.
The development flake is independent of normal application updates.

Boot images must contain a complete 96 MiB image with valid AVB metadata; a short
raw Android image can leave a stale footer and return to Fastboot. The builder
adds and verifies that metadata. The boot filesystem label is uppercase
`FP6-BOOT`, matching FAT's actual label.

Recovery archives and the original phone partition backups are private artifacts,
not repository files. The existing archives remain in the original
`../nixos-fp6/.build/recovery` workspace; preserve them separately from the Git repo.
Do not change slots with qbootctl or relock the bootloader during recovery.

The first working image was NixOS 26.05 with the 7.2.0 device kernel. USB SSH,
root growth, `/boot` and the firewall were verified through a reboot. Morf and
touch input have also been tested. Mobile data, calls and cameras still need
hardware testing.
