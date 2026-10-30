{ nixosHardware, ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
    ../shared/uefi.nix
    nixosHardware.nixosModules.microsoft-surface-pro-intel
  ];
  networking.hostName = "surf";
}
