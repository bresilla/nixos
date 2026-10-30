{ ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
    ../shared/uefi.nix
    "${import ./nixos-hardware.nix}/microsoft/surface/surface-pro-intel"
  ];
  networking.hostName = "surf";
}
