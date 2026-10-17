# U-Boot on the FP6

Notes on booting the FP6 through U-Boot instead of an Android boot image (as of
2026-10). Nothing here is implemented yet.

## Current boot path

ABL (Qualcomm's signed Android bootloader) loads `boot_a`, an Android boot image
that `hardware.nix` builds with mkbootimg and an AVB footer. It holds the kernel,
initrd, `milos-fairphone-fp6.dtb` and a command line with `nixos.init=`.
`update-boot.sh` repacks and writes it on every update.

The kernel is already mainline-based: `development/flake.nix` builds
`github:milos-mainline/linux` (7.2.0) with postmarketOS's config, and the
device tree reports `fairphone,fp6 qcom,milos`. Only the boot path is Android.

## What U-Boot would change

- ABL stays as the first stage. It is signed and cannot be replaced on a retail
  phone; it would load U-Boot from `boot_a` instead of the kernel.
- U-Boot provides UEFI and starts systemd-boot from `FP6-BOOT`, so the phone boots
  like the laptops: NixOS generations in a boot menu, kernel and initrd on `/boot`.
- `boot_a` is written once, only when U-Boot itself changes.
- `update-boot.sh`, the mkbootimg/avbtool image builder and the
  `initrd-find-nixos-closure` override in `hardware.nix` could go.
- No hardware support is lost, since the kernel and device tree stay the same.

## Upstream status

- Milos (SM7635) support is in mainline U-Boot, from Luca Weiss (Fairphone):
  pinctrl and clock drivers (2026-04-27), UFS and TCSRCC clocks (2026-06-30).
  Included in v2026.10.
- Tested on the FP6: earlycon, UART, USB, UFS, SD card, power and volume keys.
- The framebuffer needs extra patches, so the boot menu may only show on the
  serial console at first.
- Qualcomm boards use the generic qcom defconfig. U-Boot is packed as an Android
  boot image with the DTB appended, and ABL chainloads it.

## Open points

- U-Boot must hand the kernel the FP6 DTB (from the kernel's `dtbs/qcom/`), either
  its own copy or through systemd-boot's `devicetree` entry.
- The ABL-added `androidboot.*` arguments disappear; check nothing relies on them
  (the WiFi MAC comes from `WifiMac=` today).
- AVB: U-Boot's image still needs a valid 96 MiB AVB footer, like the current image.

## Safe test

Build U-Boot for Milos as a boot image and run it once with `fastboot boot`, which
does not flash anything. A reboot returns to the current `boot_a`. Only flash
`boot_a` after U-Boot, systemd-boot and the kernel all start from it.

## Sources

- U-Boot Milos bring-up (March 2026): https://ratatoskr.run/u-boot/2026/03/10315241/t
- U-Boot Qualcomm docs: https://github.com/u-boot/u-boot/blob/master/doc/board/qualcomm/board.rst
- Linaro, U-Boot for Qualcomm: https://www.linaro.org/blog/initial-u-boot-release-for-qualcomm-platforms/
- Linaro, unified boot on RBx: https://www.linaro.org/blog/unified-boot-on-qualcomm-rbx-development-boards/
- FOSDEM 2024, U-Boot on Qualcomm phones: https://archive.fosdem.org/2024/events/attachments/fosdem-2024-1716-u-boot-for-modern-qualcomm-phones/slides/22104/fosdem24_aDevbas.pdf
- U-Boot SPL for Qualcomm (May 2026): https://ratatoskr.run/u-boot/2026/05/17017478/t
