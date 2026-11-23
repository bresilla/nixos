{ ... }:
{
  imports = [
    ../../device-recipes/microsoft-surfacepro5/software/hardware.nix
    ../../device-recipes/microsoft-surfacepro5/software/surface.nix
    ./storage.nix
   
  ];
  networking.hostName = "surf";
}
