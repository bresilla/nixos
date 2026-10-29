{
  imports = [ ./hardware.nix ./disko.nix ../shared/uefi.nix ];
  networking.hostName = "nest";
  boot.swraid.mdadmConf = "MAILADDR root";
}
