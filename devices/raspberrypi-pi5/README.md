# Raspberry Pi 5 (rasp)

Boots from an SD card. Build the image on tron, flash it, then seed /etc/nixos
and the password on the card before the first boot:

```sh
nix build path:.#packages.aarch64-linux.rasp-image
caligula burn result/sd-image/*.img.zst
```

The root partition (`NIXOS_SD`) grows to the whole card on first boot.
Board-specific hardware (the CAN HAT overlay) lives in `/etc/nixos/local.nix`.
