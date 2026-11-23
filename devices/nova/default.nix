{
  imports = [
    ../../device-recipes/lenovo-t480/software/hardware.nix
    ../../device-recipes/lenovo-t480/software/coreboot.nix
   
    ./storage.nix
    ../../device-recipes/lenovo-t480/software/modem.nix
  ];
  networking.hostName = "nova";
}
