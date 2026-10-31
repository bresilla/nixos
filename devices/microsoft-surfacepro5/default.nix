{ ... }:
{
  imports = [
    ../../device-recipes/microsoft-surfacepro5/software/hardware.nix
    ./storage.nix
    ../shared/uefi.nix
    "${import ../../device-recipes/microsoft-surfacepro5/software/nixos-hardware.nix}/microsoft/surface/surface-pro-intel"
  ];
  networking.hostName = "surf";
}
