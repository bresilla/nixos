{ lib, ... }:
{
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "usbhid" "usb_storage" "uas" "sd_mod" ];
  # The GB10's USB controllers are platform devices, not PCI; load them in the initrd.
  boot.initrd.kernelModules = [ "xhci_plat_hcd" "hid_generic" ];
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
