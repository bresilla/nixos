# Aetina AIB-MN02 + Jetson Orin NX 8 GB (hostname `orin`)

NixOS (iot profile) on JetPack 7.2.1: Jetson Linux R39.2.1 firmware, kernel 6.8, CUDA 13.
LAN only, no NetBird: the Realtek port (`wire`) takes DHCP on the office LAN, at
192.168.1.170 when this was written.

- Module: P3767-0001 (Orin NX 8 GB). Carrier: Aetina AIB-MN02, which Aetina's BSP
  describes under NVIDIA's devkit name (`jetson-orin-nano-devkit`).
- Storage: the 447 GB NVMe holds the EFI partition and the LVM pool (`/`, `/nix`, swap,
  `/doc`). NVIDIA's boot firmware lives on the module's QSPI, in A/B slots.
- Ethernet: Realtek 8168 on PCIe C8 (`wire`) and Intel I210 on C7 (`enP7p1s0`).
- `board/`: what the original Ubuntu ran (Aetina's R35.4.1 device tree and boot setup);
  `board/r36/`: the files taken from Aetina's R36.4.3 patch for this board.

## The board's differences from NVIDIA's devkit

Aetina's patch (aetina.com downloads, `PATCH_R36_4_3_Orin_NX-Nano_AIB-MO02-MN02_v1.0.1`)
copies its files over NVIDIA's BSP. Against NVIDIA's own files, which are identical in R35,
R36 and R39, only these matter for the firmware:

- `tegra234-mb1-bct-pinmux-p3767-dp-a03.dtsi` and `tegra234-mb1-bct-gpio-p3767-dp-a03.dtsi`:
  the board's pins and GPIOs.
- `tegra234-mb2-bct-misc-p3767-0000.dts`: `cvb_eeprom_read_size = 0`, as the board has no
  carrier EEPROM. With NVIDIA's value the firmware installs but never boots (capsule
  status 2).
- `ODMDATA` `gbe-uphy-config-9` in `p3767.conf.common`: the lane split that gives the Intel
  Ethernet its PCIe link.

`default.nix` applies them through jetpack-nixos's `flashScriptOverrides.postPatch`.
JetPack 5 and 6 also use Aetina's device tree for the kernel; JetPack 7 uses NVIDIA's devkit
tree, since Aetina has none for the 6.8 kernel.

## Firmware updates

The USB-C OTG port never enumerated on any host, so the firmware cannot be flashed over
USB recovery. It moves by UEFI capsule instead, from NixOS:

1. Set `jetpack` in `default.nix` and build the system and
   `config.system.build.uefiCapsuleUpdate` on an ARM builder (lama).
2. Copy both over, then on orin:
   `nix-env -p /nix/var/nix/profiles/system --set <system>`,
   `<system>/bin/switch-to-configuration boot`,
   `ota-apply-capsule-update <file>.Cap`, reboot, and keep the power on.
3. Check with `ota-check-firmware` and `nvbootctrl dump-slots-info`.

A failed update rolls back to the other slot; the previous generation in the systemd-boot
menu then boots again. Its climb, one major version at a time: Aetina's R35.4.1 → 35.6.5 →
36.5.2 → 39.2.1. R35.4.1 rejects an R36 capsule outright (`NO_PROTOCOL_FOR_IMAGE`), so
JetPack 5's latest firmware has to come first.

## JetPack 5 and the installer

The install ran from jetpack-nixos's JetPack 5 installer on a USB stick, which matches the
R35 firmware. NVIDIA's 5.10 kernel lacks some options, now in `boot.kernelPatches`:
device-mapper targets for LVM, nftables expressions for the firewall, and the crypto API
iwd needs. Its btrfs volumes are made without `block-group-tree`, which 5.10 cannot mount.
