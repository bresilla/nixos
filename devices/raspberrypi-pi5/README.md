# Raspberry Pi 5 (rasp)

Boots from an SD card. Build the image on tron, flash it, then seed /etc/nixos
and the password on the card before the first boot:

```sh
nix build path:.#packages.aarch64-linux.rasp-image
caligula burn result/sd-image/*.img.zst
```

The root partition (`NIXOS_SD`) grows to the whole card on first boot.
Board-specific hardware (the CAN HAT overlay) lives in `/etc/nixos/local.nix`.

## NVMe

A Pi with an M.2 NVMe sets `storage = "nvme";` in `/etc/nixos/machine.nix`; the
device then uses `nvme.nix` (firmware partition plus LVM: root 40G, nix 100G,
swap 8G, doc the rest) instead of the SD-image layout. Install it with
nixos-anywhere from the SD system, then put NVMe first in the EEPROM so it boots
with the card still in:

```sh
sudo rpi-eeprom-config --edit   # BOOT_ORDER=0xf416
```
