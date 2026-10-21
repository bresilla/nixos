{ lib, jetpack-nixos, ... }:
{
  imports = [ jetpack-nixos.nixosModules.default ./disko.nix ];
  networking.hostName = "orin";

  # JetPack 5 (L4T R35, CUDA 11) to match the R35 firmware it shipped with; its OTG port never
  # reached a host, so the firmware moves to 6 and then 7 by capsule updates from NixOS.
  # Aetina's carrier is NVIDIA's devkit wiring with small
  # changes (see README); the devkit tree boots it, and those changes come later as an overlay.
  hardware.nvidia-jetpack = {
    enable = true;
    som = "orin-nx";
    carrierBoard = "devkit";
    majorVersion = "5";
    # JetPack 5 is only the step to 7 here; its CUDA 11.4 needs GCC 10, which no longer builds.
    configureCuda = false;
  };

  # NVIDIA's kernel has device-mapper but not these targets; LVM loads dm-snapshot at boot.
  boot.kernelPatches = [
    {
      name = "lvm-targets";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        DM_SNAPSHOT = module;
        DM_THIN_PROVISIONING = module;
        DM_MIRROR = module;
      };
    }
  ];

  # JetPack is NVIDIA's: L4T firmware, the CUDA libraries and their tools are all unfree.
  nixpkgs.config.allowUnfree = true;

  # The Jetson UEFI firmware on the module's QSPI starts systemd-boot from the NVMe.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
