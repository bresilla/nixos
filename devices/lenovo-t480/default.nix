{
  imports = [
    ../../device-recipes/lenovo-t480/software/hardware.nix
    ../shared/uefi.nix
    ./disko.nix
    ../../device-recipes/lenovo-t480/software/modem.nix
  ];
  networking.hostName = "nova";
}
