# AYN Odin 3

NixOS on the Odin 3 (Snapdragon 8 Elite, SM8750), booting from a USB drive next
to the Armada OS installation on internal storage. It reuses Armada's work: its
kernel patches, device trees, config fragment and firmware, pinned to one Armada
commit in `kernel.nix`.

- `kernel.nix`: kernel 7.2.6 with Armada's patch series, built with its own pinned
  nixpkgs so system updates never rebuild it; also Armada's Odin 3 firmware.
- `kernel.config`: the generated configuration (defconfig, Armada's fragment, then
  `kernel.fragment`). Regenerate after changing the kernel:
  `nix build path:.#odin3-kernel-config` and copy the result here.
- `dtbs`: Armada's DTB list; `/KERNEL` appends them in this order for the ABL's
  model picker.
- `boot.nix`: builds `/KERNEL` and rewrites it on every switch.
- `storage.nix`: partitions, first-boot growth and the USB drive image.
- `provision.sh`: adds Wi-Fi and a password to a written drive.

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
sudo bash devices/odin3/provision.sh /dev/sdX
```

Plug the drive into the Odin 3, set the ABL's Linux source to USB and start.
The root partition grows to fill the drive on first boot. SSH in over Wi-Fi
(the hostname is `odin3`), then save the identity in `/etc/nixos` like other
machines (`machine.nix`: `{ profile = "iot"; device = "odin3"; }`).

The first update on the device compiles the kernel natively, since the image's
cross-compiled kernel has a different store path. Later updates reuse it.

## Status

Not yet boot-tested. Armada's kernel supports display, touch, audio, Wi-Fi,
Bluetooth, GPU, fan and the controls; this configuration starts with a console,
Wi-Fi and SSH. The USB-C port needs the ADSP running for host mode, so the
initrd loads the ADSP firmware before mounting the root drive.
