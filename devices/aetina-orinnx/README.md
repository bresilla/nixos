# Aetina AIB-MN02 + Jetson Orin NX 8 GB (hostname `orin`)

Not on NixOS yet. Today it runs NVIDIA's L4T R35.4.1 (JetPack 5.1.2, kernel 5.10,
CUDA 11.4) from Aetina's BSP, with an Ubuntu 24.04 userland, at 192.168.1.53 on the
office LAN (also `orin.zerotier`, 172.30.0.248). SSH as `nvidia` with the usual keys.

- Module: P3767-0001 (Orin NX 8 GB). Carrier: Aetina AIB-MN02, which Aetina's BSP
  describes under NVIDIA's devkit name (`tegra234-p3767-0001-p3768-0000-a0.dtb`).
- Storage: one 447 GB NVMe holding the root (`p1`), NVIDIA's boot partitions and a 64 MB
  EFI partition (`p10`).
- `board/`: the device tree, boot setup, kernel config and package list captured from
  the running system (see `board/README.md`).

## How Aetina's board differs from NVIDIA's devkit

`board/aetina-vs-devkit.diff` compares Aetina's DTB with NVIDIA's stock R35.4.1 devkit
DTB for the same module, both decompiled and sorted. About 960 of its 1,039 changed
lines are phandles renumbered by one extra node. The real changes are board wiring only,
no new drivers:

- PCIe: controllers narrowed to x1, and one more controller enabled.
- USB: port `usb3-2` added; a micro-USB device connector (with its VBUS GPIO) for OTG.
- Display: Aetina's own `dcb-image`.
- A few pad and node `status` flips to match the board.

So no kernel patches are needed: NVIDIA's kernel for the module plus these changes.

## Plan: NixOS on JetPack 7.2.1

The newest JetPack for the Orin family is 7.2.1 (Jetson Linux R39.2.1, Aug 2026): Ubuntu
24.04 base, kernel 6.8, CUDA 13. jetpack-nixos (github:anduril/jetpack-nixos) supports
it on the Orin NX.

1. Recreate Aetina's changes above as a device-tree overlay on NVIDIA's R39 devkit tree;
   Aetina's R35 DTB does not fit the R39 kernel, and Aetina has no R39 BSP.
2. Device config: `hardware.nvidia-jetpack` with `som = "orin-nx"`,
   `carrierBoard = "devkit"`, `majorVersion = "7"`, the overlay, hostname `orin`.
3. Flash R39 firmware to the module's QSPI from tron (x86) with the board in USB
   recovery mode: R35 to R39 is a major jump, so not a capsule update from Linux.
   This needs someone at the device.
4. Boot jetpack-nixos's installer from a USB stick and install over the LAN from tron.
   Set the user password before the first reboot (nixos-anywhere skips it).
5. Check on the hardware: Ethernet, PCIe/M.2, USB 3 (including `usb3-2`), the display.

Remote alternatives are worse: kexec into an installer failed on lama's NVIDIA boot
chain, and converting Ubuntu in place leaves the board unreachable if the first boot
fails.
