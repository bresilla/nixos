{ lib, ... }:
let
  link = lib.importJSON ./link.json;
in
{
  imports = [ ../../device-recipes/beelink-memini/software/hardware.nix ./storage.nix ./services/subvolumes.nix ./services/nfs.nix ./services/backup.nix ./services/status.nix ./services/dump.nix ];
  networking.hostName = "nest";

  # No module loads after boot; modules.txt is what nest uses (lsmod).
  bresilla.server.kernelModules = ./modules.txt;

  # Direct cable to hive, for NFS.
  networking.networkmanager.ensureProfiles.profiles.hive-link = {
    connection = { id = "hive-link"; type = "ethernet"; autoconnect-priority = 10; };
    ethernet.mac-address = "78:55:36:02:1f:a9";
    ipv4 = { method = "manual"; address1 = "${link.nest}/${toString link.prefix}"; never-default = true; };
    ipv6.method = "disabled";
  };
}
