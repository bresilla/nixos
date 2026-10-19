{ lib, ... }:
{
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "usbhid" "usb_storage" "uas" "sd_mod" ];
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
