{ jetpack-nixos, ... }:
{
  imports = [ jetpack-nixos.nixosModules.default ./disko.nix ];
  networking.hostName = "orin";

  # JetPack 7.2 (L4T R39, CUDA 13). Aetina's carrier is NVIDIA's devkit wiring with small
  # changes (see README); the devkit tree boots it, and those changes come later as an overlay.
  hardware.nvidia-jetpack = {
    enable = true;
    som = "orin-nx";
    carrierBoard = "devkit";
    majorVersion = "7";
  };

  # JetPack is NVIDIA's: L4T firmware, the CUDA libraries and their tools are all unfree.
  nixpkgs.config.allowUnfree = true;

  # The Jetson UEFI firmware on the module's QSPI starts systemd-boot from the NVMe.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
