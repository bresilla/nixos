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
    # Every output is wired to the iGPU; the RTX 3050 Ti only renders on demand.
    nvidia = {
      enable = true;
      prime = {
        offload.enable = true;
        intelBusId = "PCI:0:2:0";
        nvidiaBusId = "PCI:1:0:0";
      };
    };
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
  # The VM's virtual disk has no SMART data; monitor the SSD on bare metal.
  systemd.services.smartd.unitConfig.ConditionVirtualization = "!vm";
}
