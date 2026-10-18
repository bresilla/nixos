# AYN Odin 3

NixOS on the Odin 3 (Snapdragon 8 Elite, SM8750), on internal storage in place of
Armada OS (or on a USB drive), keeping Android, with the `handheld` profile:
Steam's gaming mode at boot and the Morf desktop one switch away. It reuses
Armada's work: kernel patches, device trees, config fragment, firmware and UCM,
pinned to one Armada commit.

- `default.nix`: device settings and Wi-Fi.
- `hardware.nix`: kernel, firmware, initrd modules and kernel arguments.
- `boot.nix`: builds `/KERNEL` and rewrites it on every switch.
- `storage.nix`: partitions, first-boot growth, the USB drive image, and keeping
  udisks and fwupd away from the internal storage.
- `display.nix`: landscape rotation, touch and scale for Morf and gamescope.
- `audio.nix`: Armada's UCM and PipeWire buffers.
- `fan.nix`: Armada's balanced fan curve; no thermal zone drives the fan.
- `suspend.nix`: Armada's fake suspend (blank, mute, hold inputs until the power
  key), for USB only: a real suspend loses the USB root drive.
- `usb-gadget.nix`: NCM networking over USB-C, as on the FP6.
- `kernel/`: the kernel build, pinned apart from the system's nixpkgs.
  - `default.nix`: kernel 7.2.6 with Armada's patch series and Odin 3 firmware.
  - `config`: the generated configuration (defconfig, Armada's fragment, then
    `fragment`). Regenerate with `nix build path:.#odin3-kernel-config`.
  - `dtbs`: Armada's DTB list, appended to `/KERNEL` in this order.
  - `initrd-modules`: the platform modules the initrd carries.
- `scripts/provision.sh`: adds Wi-Fi and a password to a written drive.
- `scripts/install-internal.sh`: moves NixOS onto internal storage in place of Armada.

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
sudo bash devices/odin3/scripts/provision.sh /dev/sdX
```

Plug the drive into the Odin 3, set the ABL's Linux source to USB and start.
The root partition grows to fill the drive on first boot. SSH in over Wi-Fi
(the hostname is `odin`), then save the identity in `/etc/nixos` like other
machines (`machine.nix`: `{ profile = "handheld"; device = "odin3"; }`).

## Install on internal storage

`bresilla.odin3.storage` selects the layout; `internal` is the default, and the
USB image sets `usb`. `internal` takes Armada's place on
the UFS and keeps Android: `ARMADA_ROOT` becomes ext4 `odin3-root` and the
`ARMADA` FAT partition becomes `ODIN3-INT`, holding `/KERNEL`. Its own labels let
a USB drive with this system stay plugged in. The fake suspend applies to USB only.

From NixOS on a USB drive, build the system with `storage = "internal"`, then:

```sh
sudo nix shell nixpkgs#dosfstools -c bash devices/odin3/scripts/install-internal.sh /nix/store/...-nixos-system-odin3-...
```

It checks that both partitions are Armada's on the internal UFS and unmounted,
asks before erasing, installs the system and copies `/etc/nixos`, the SSH host
keys, Wi-Fi connections, `/etc/shadow`, `/home` and Decky's state. Then set the
ABL's Linux boot source to internal.

## Kernel updates

The kernel is always cross-compiled on x86_64, so updates on the device reuse
the kernel already in its store and never compile one. After changing the
kernel, build it on an x86_64 machine and copy it to the device (the device
trusts `wheel` for this) before updating.

## USB

The USB-C port defaults to host mode (`role-switch-default-mode` in
`kernel/default.nix`), since UCSI often fails to set the role while the root
drive sits on it. The ABL's own USB detection still depends on the plug's
orientation; flip it if the ABL reports no media.

`usb-gadget.nix` starts only when the controller enters device mode, which never
happens while the root drive is on USB. Laptops with `phoneUsbShare` name it
`odin0` and share their connection. For an internal installation, drop the host
default so the port can become a device again.
