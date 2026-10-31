{
  imports = [ ../../device-recipes/onlogic-k800/software/hardware.nix ./disko.nix ../shared/uefi.nix ];
  networking.hostName = "logi";
}
