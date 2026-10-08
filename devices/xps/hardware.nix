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
  };
  # This XPS has no cellular modem requiring the development modem packages.
  bresilla.features.network.cellular.enable = false;
  # Keep virtual storage available while preparing the physical SSD in QEMU.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.resumeDevice = "/dev/pool/swap";
}
