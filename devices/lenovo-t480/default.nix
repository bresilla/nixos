{
  imports = [
    ./hardware.nix
    ./disko.nix
    ../../device-recipes/lenovo-t480/software/modem.nix
  ];
  networking.hostName = "nova";
}
