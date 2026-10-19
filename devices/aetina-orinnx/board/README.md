# Aetina AIB-MN02 with a Jetson Orin NX 8 GB (hostname orin)

Captured from the running L4T R35.4.1 (JetPack 5.1.2) system on 2026-10-19, before any
NixOS work. Aetina's BSP replaced NVIDIA's devkit device tree with its own, under the
devkit's file name:

- `kernel_tegra234-p3767-0001-p3768-0000-a0.dtb`: the DTB the board boots
  (`extlinux.conf` FDT), built from `R35_4_1_Orin_NX_AIB-MO02-MN02_v3_STD_Aetina.dts`.
- `running.dts`: the live tree, decompiled from `/proc/device-tree`.
- `extlinux.conf`, `cmdline.txt`: how L4T boots it.
- `kernel.config`, `lsmod.txt`: the running 5.10.120-tegra kernel and its modules.
- `packages.txt`, `nv_tegra_release`, `nv_boot_control.conf`: the L4T, CUDA and
  bootloader versions installed.
