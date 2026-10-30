{ lib, nixosHardware, surfKernelNixpkgs, ... }:
let
  # The Surface module evaluated against the pinned nixpkgs, only for its kernel:
  # the same sources give the same kernel, already built and in surf's store.
  kernelSystem = surfKernelNixpkgs.lib.nixosSystem {
    modules = [
      nixosHardware.nixosModules.microsoft-surface-pro-intel
      { nixpkgs.hostPlatform = "x86_64-linux"; }
    ];
  };
in
{
  imports = [
    ./hardware.nix
    ./disko.nix
    ../shared/uefi.nix
    nixosHardware.nixosModules.microsoft-surface-pro-intel
  ];
  networking.hostName = "surf";
  boot.kernelPackages = lib.mkForce kernelSystem.config.boot.kernelPackages;
}
