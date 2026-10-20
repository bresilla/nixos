{ lib, nixos-raspberrypi, ... }:
{
  # Vendor kernel and firmware from nixos-raspberrypi, prebuilt on its Cachix.
  imports = with nixos-raspberrypi.nixosModules; [
    nixpkgs-rpi
    nixos-raspberrypi.lib.inject-overlays
    trusted-nix-caches
    raspberry-pi-5.base
    raspberry-pi-5.display-vc4
    raspberry-pi-5.bluetooth
    sd-image
  ];
  networking.hostName = "rasp";
  # The SD-image base profile adds ZFS, which would mean compiling it for this kernel.
  boot.supportedFilesystems.zfs = lib.mkForce false;
  # An SD card has no SMART data, so smartd only fails.
  services.smartd.enable = lib.mkForce false;
}
