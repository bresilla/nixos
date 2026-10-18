{ lib, ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];
  # Keep the network identity of the Arch install this machine replaces.
  networking.hostName = "core";
  # This install created libvirtd as 993 before NixOS's fixed 67; keep it.
  users.groups.libvirtd.gid = lib.mkForce 993;
}
