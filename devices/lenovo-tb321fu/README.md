# Lenovo Legion Tab Gen 3 (TB321FU, hostname `lego`)

NixOS on the 8.8" Legion Tab Gen 3 / Legion Y700 2025 (Snapdragon 8 Gen 3, SM8650), with
the `handheld` profile: Morf and eva at boot, with the Lenovo Tab Pen Plus (AP500U). It
replaces Android and reuses the kernel patches, device trees, firmware and boot chain of
[Armada for the TB321FU](https://github.com/enij90/armada-tb321fu), pinned to one commit.

This folder holds what is specific to this machine:

- `default.nix`: device settings and Wi-Fi.
- `storage.nix`: partitions and the three images the install flashes.

Hardware support lives in [bresilla/devices](https://github.com/bresilla/devices), under
`lenovo-tb321fu/`, and reaches machines through the `device-recipes` pin:

- `firmware/`: Armada's firmware, and `loader/`, the UEFI loader and GRUB.
- `kernel/`: kernel 7.2.6 with Armada's series; accepts the AP500U's pen reports.
- `software/hardware.nix`: kernel, firmware, initrd modules and kernel arguments.
- `software/boot.nix`: writes the kernel and GRUB menu on every switch.
- `software/display.nix`: landscape rotation for the screen, touch and pen.
- `software/pen.nix`: the pen as an on-screen tablet.
- `software/audio.nix`: Armada's UCM.
- `software/usb-gadget.nix`: NCM networking over USB-C.
- `software/scripts/provision.sh`: adds Wi-Fi and a password to the images.

Not ported yet: cameras, the sensor hub (auto-rotate, light sensor) and haptics, which
need Armada's libcamera patches, hexagonrpc and libssc.

## Boot

The stock bootloader starts `boot_a`, a UEFI loader built by GUF296. It starts GRUB
from the FAT filesystem at the start of the `super` partition, which is `/boot` here.
Each switch writes a generation to `/boot/current` and keeps the last one in
`/boot/previous`, listed in the menu shown for 3 seconds at power-on.

The panel is BOE or CSOT, and each needs its own device tree. BOE is the default. If the
screen stays black after the logo, press Volume Down at the menu to pick
**NixOS (other panel)**. On a CSOT unit, `sudo touch /boot/panel-csot` and switch again.

## Install

This wipes the tablet, and Android with it.

1. On Android, update to the latest firmware (ZUI 17.5.10.319 was Armada's). Armada was
   tested on the global build; Chinese firmware is untested.
2. Enable Developer options, then **OEM unlocking** and **USB debugging**.
3. Get the unlock file for the serial number, for example from lenovobl.neko.ink, and:

   ```sh
   adb reboot bootloader
   fastboot flash unlock sn.img
   fastboot oem unlock-go
   ```

4. Build the images on an aarch64 builder such as lama, and add Wi-Fi and a password:

   ```sh
   nix build .#packages.aarch64-linux.tb321fu-images
   sudo device-recipes/lenovo-tb321fu/software/scripts/provision.sh result /var/tmp/lego
   ```

5. In fastboot (Volume Down + Power, or `adb reboot bootloader`):

   ```sh
   cd /var/tmp/lego
   fastboot flash boot_a boot.img
   fastboot flash super super.img
   fastboot -S 700M flash userdata userdata.simg
   fastboot reboot
   ```

Once it boots, finish as on any machine: clone `~/.dot` and write `/etc/nixos`.

The first boot grows the root over `userdata`. Over USB-C it appears as `lego0` on a
computer with this configuration, with NCM networking.

## Recovery

Fastboot stays reachable through Volume Down + Power. To go back to Android, flash
Lenovo's stock firmware for the TB321FU; the bootloader stays unlocked.
