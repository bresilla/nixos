{
  imports = [ ./hardware.nix ./disko.nix ./gitea.nix ../shared/uefi.nix ];
  networking.hostName = "hive";
  boot.swraid.mdadmConf = "MAILADDR root";

  # Direct cable to nest, for NFS.
  networking.networkmanager.ensureProfiles.profiles.nest-link = {
    connection = { id = "nest-link"; type = "ethernet"; autoconnect-priority = 10; };
    ethernet.mac-address = "1c:83:41:31:2b:56";
    ipv4 = { method = "manual"; address1 = "10.99.0.1/24"; never-default = true; };
    ipv6.method = "disabled";
  };
}
