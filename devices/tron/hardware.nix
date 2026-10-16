{ modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ../shared/uefi.nix
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
  bresilla.features.system = {
    architecture = "x86_64";
    cpuVendor = "intel";
    # The i7-13700KF has no iGPU; the RTX 4080 drives every output.
    nvidia.enable = true;
  };
  # A desktop without a cellular modem.
  bresilla.features.network.cellular.enable = false;
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.resumeDevice = "/dev/pool/swap";
}
