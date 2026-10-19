{
  imports = [ ./hardware.nix ./disko.nix ../shared/uefi.nix ];
  networking.hostName = "logi";
}
