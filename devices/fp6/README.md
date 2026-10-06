# Fairphone 6

This is the FP6 we boot-tested, not the FP5. It uses the Android bootloader and
a device-specific kernel. A PC live-USB Disko installation is not suitable.

- `hardware.nix`: kernel, firmware, USB gadget and Android boot-image builder.
- `storage.nix`: nested 4096-byte-sector GPT inside Android `userdata`, root growth
  and the `FP6-BOOT` filesystem label. This uses systemd-repart, not Disko.
- `device.nix`: USB networking and kernel-specific settings.
- `kernel.nix` and `firmware.nix`: build recipes.
- `development/shell.nix`: kernel/image inspection and Fastboot tools.
- `update-boot.sh`: checked boot-image updates on the installed FP6 (slot A).

The shared `#phone` profile supplies applications and accounts. In the repository
checkout on this phone, `machine.nix` selects it:

```nix
{ profile = "phone"; device = "fp6"; }
```

Keep `user.nix` and the selected `dotfiles.nix` on the device. Neither contains a
plaintext password. SSH uses the account's authorized keys; change its password
interactively with `passwd`.

## Updating the installed phone

Run `curl -fsSL https://nix.bresilla.dev | bash` on the phone and choose Update.
It resolves current inputs, builds natively, applies the system and writes the
matching verified boot image. A plain `nixos-rebuild switch` alone does not update
the Android boot partition. The equivalent manual steps, from `/etc/nixos`, are:

```sh
sudo nix flake update --refresh --flake path:.
boot=$(sudo nix build --no-link --print-out-paths path:.#fp6-boot)
sudo bash devices/fp6/update-boot.sh --check "$boot"
sudo nixos-rebuild switch --flake path:.#phone
sudo bash devices/fp6/update-boot.sh "$boot"
```

For a first installation, build `fp6-userdata` and `fp6-boot`, then use Fastboot to
flash `userdata` and `boot_a`, and erase `dtbo_a`. This replaces phone data and
requires the unlocked bootloader, verified backups and slot A selected. Check the
device identity before any flash. Never run a generic Disko erase on the phone.

## Development and recovery

From the repository root, `nix develop .#fp6` opens the tool environment. On x86_64,
`nix build .#fp6-kernel` cross-compiles only the kernel. Full x86-hosted phone image
builds also need an ARM64 builder for the NixOS userspace. On the phone, builds are
native ARM64.

Boot images must contain a complete 96 MiB image with valid AVB metadata; a short
raw Android image can leave a stale footer and return to Fastboot. The builder
adds and verifies that metadata. The boot filesystem label is uppercase
`FP6-BOOT`, matching FAT's actual label.

Recovery archives and the original phone partition backups are private artifacts,
not repository files. The existing archives remain in the original
`../nixos-fp6/.build/recovery` workspace; preserve them separately from the Git repo.
Do not change slots with qbootctl or relock the bootloader during recovery.

The first working image was NixOS 26.05 with the 7.2.0 device kernel. USB SSH,
root growth, `/boot` and the firewall were verified through a reboot. Mobile data,
calls, cameras and a graphical phone interface still need hardware testing.
