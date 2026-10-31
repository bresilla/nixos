# AYN Odin 3

NixOS on the Odin 3 (Snapdragon 8 Elite, SM8750), on internal storage in place of
Armada OS (or on a USB drive), keeping Android, with the `handheld` profile:
Steam's gaming mode at boot and the Morf desktop one switch away. It reuses
Armada's work: kernel patches, device trees, config fragment, firmware and UCM,
pinned to one Armada commit.

This folder holds what is specific to this machine:

- `default.nix`: device settings and Wi-Fi.
- `storage.nix`: partitions, first-boot growth, the USB drive image, and keeping
  udisks and fwupd away from the internal storage.

Hardware support lives in [bresilla/devices](https://github.com/bresilla/devices),
under `ayn-odin3/`, and reaches machines through the `device-recipes` pin:

- `firmware/`: Armada's Odin 3 firmware, built by CI into `/firmwares`.
- `kernel/`: the kernel build, pinned apart from the system's nixpkgs.
  - `default.nix`: kernel 7.2.6 with Armada's patch series.
  - `config`: the generated configuration (defconfig, Armada's fragment, then
    `fragment`). Regenerate with `nix build path:.#odin3-kernel-config`.
  - `dtbs`: Armada's DTB list, appended to `/KERNEL` in this order.
  - `initrd-modules`: the platform modules the initrd carries.
- `software/hardware.nix`: kernel, firmware, initrd modules and kernel arguments.
- `software/boot.nix`: builds `/KERNEL` and rewrites it on every switch.
- `software/display.nix`: landscape rotation, touch and scale for Morf and gamescope.
- `software/audio.nix`: Armada's UCM and PipeWire buffers.
- `software/fan.nix`: Armada's balanced fan curve; no thermal zone drives the fan.
- `software/suspend.nix`: Armada's fake suspend (blank, mute, hold inputs until the
  power key), for USB only: a real suspend loses the USB root drive.
- `software/usb-gadget.nix`: NCM networking over USB-C, as on the FP6.
- `software/scripts/provision.sh`: adds Wi-Fi and a password to a written drive.
- `software/scripts/install-internal.sh`: moves NixOS onto internal storage in place of Armada.

## Boot

Armada installs ROCKNIX-ABL, a replacement Android bootloader. Its menu (hold
Volume Down at power-on) chooses Android or Linux and the Linux source: internal
storage, SD card or USB. Hold Volume Up at power-on to pick once.

In Linux mode it loads `/KERNEL` from the first FAT partition: an Android
header-v0 boot image (gzip kernel with DTBs appended, initrd, command line of at
most 512 bytes). Each `nixos-rebuild switch` writes a new `/KERNEL` for the default
generation and keeps the previous one as `KERNEL.BAK`. To roll back, rename
`KERNEL.BAK` to `KERNEL` on the `ODIN3-BOOT` partition from any computer.

## Install on a USB drive

Built on an x86_64 machine with aarch64 emulation (the workstation profile has it);
the image cross-compiles its kernel. Keep `user.nix` in the checkout, as for any build.

```sh
nix build path:.#odin3-image
zstdcat result | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sudo bash device-recipes/ayn-odin3/software/scripts/provision.sh /dev/sdX
```

Plug the drive into the Odin 3, set the ABL's Linux source to USB and start.
The root partition grows to fill the drive on first boot. SSH in over Wi-Fi
(the hostname is `odin`), then save the identity in `/etc/nixos` like other
machines (`machine.nix`: `{ profile = "handheld"; device = "ayn-odin3"; }`).

## Install on internal storage

`bresilla.odin3.storage` selects the layout; `internal` is the default, and the
USB image sets `usb`. `internal` takes Armada's place on
the UFS and keeps Android: `ARMADA_ROOT` becomes ext4 `odin3-root` and the
`ARMADA` FAT partition becomes `ODIN3-INT`, holding `/KERNEL`. Its own labels let
a USB drive with this system stay plugged in. The fake suspend applies to USB only.

From NixOS on a USB drive, build the system with `storage = "internal"`, then:

```sh
sudo nix shell nixpkgs#dosfstools -c bash device-recipes/ayn-odin3/software/scripts/install-internal.sh /nix/store/...-nixos-system-odin3-...
```

It checks that both partitions are Armada's on the internal UFS and unmounted,
asks before erasing, installs the system and copies `/etc/nixos`, the SSH host
keys, Wi-Fi connections, `/etc/shadow`, `/home` and Decky's state. Then set the
ABL's Linux boot source to internal.

## Kernel updates

Tron cross-compiles the kernel into `/kernels`, so updates on the device download
it and never compile one. To change it, edit `ayn-odin3/kernel/` in bresilla/devices,
run `make kernels` there, and push; CI publishes the recipe only once every kernel
is in `/kernels`.

## USB

The USB-C port defaults to host mode (`role-switch-default-mode` in the kernel
recipe's `default.nix`), since UCSI often fails to set the role while the root
drive sits on it. The ABL's own USB detection still depends on the plug's
orientation; flip it if the ABL reports no media.

The role switch never leaves that default on its own, so usb-signaller (from the
handheld profile) sets it from the Type-C data role: device on a computer, with
developer mode, and host otherwise. `usb-mode` switches modes as on the FP6.
Laptops with `phoneUsbShare` name the developer link `odin0` and the tethering
one `odint0`. `software/usb-gadget.nix` keeps the plain NCM gadget for when usb-signaller
is off; neither works while the root drive is on USB.
