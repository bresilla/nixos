{
  imports = [ ./hardware.nix ./disko.nix ./nfs.nix ../shared/uefi.nix ];
  networking.hostName = "nest";
  boot.swraid.mdadmConf = "MAILADDR root";

  # Direct cable to hive, for NFS.
  networking.networkmanager.ensureProfiles.profiles.hive-link = {
    connection = { id = "hive-link"; type = "ethernet"; autoconnect-priority = 10; };
    ethernet.mac-address = "78:55:36:02:1f:a9";
    ipv4 = { method = "manual"; address1 = "10.99.0.2/24"; never-default = true; };
    ipv6.method = "disabled";
  };
}
