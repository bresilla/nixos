{ lib, ... }:
{
  imports = [ ../../device-recipes/beelink-memini/software/hardware.nix ./storage.nix ./services/subvolumes.nix ./services/nfs.nix ../shared/uefi.nix ];
  networking.hostName = "nest";
  boot.swraid.mdadmConf = "MAILADDR root";

  # No module loads after boot. modules.txt is what nest uses (lsmod) plus USB disk
  # drivers, loaded up front; add to it for new needs.
  security.lockKernelModules = true;
  boot.kernelModules = lib.filter (m: m != "") (lib.splitString "\n" (builtins.readFile ./modules.txt));

  # Direct cable to hive, for NFS.
  networking.networkmanager.ensureProfiles.profiles.hive-link = {
    connection = { id = "hive-link"; type = "ethernet"; autoconnect-priority = 10; };
    ethernet.mac-address = "78:55:36:02:1f:a9";
    ipv4 = { method = "manual"; address1 = "10.99.0.2/24"; never-default = true; };
    ipv6.method = "disabled";
  };
}
