{ lib, ... }:
{
  imports = [
    ../../device-recipes/dell-xps15/software/hardware.nix
    ../shared/uefi.nix
    ./storage.nix
  ];
  # Keep the network identity of the Arch install this machine replaces.
  networking.hostName = "core";
  # This install created libvirtd as 993 before NixOS's fixed 67; keep it.
  users.groups.libvirtd.gid = lib.mkForce 993;
  # Being tried out here first: a pattern for the lock screen and greeter.
  bresilla.security.patty = { enable = true; services = [ "eva-lock" "greetd" ]; };
  # And the YubiKeys as an alternative: a touch to unlock, touch and the key's FIDO2 PIN for sudo.
  bresilla.security.u2f = { enable = true; touch = [ "eva-lock" "greetd" ]; touchAndPin = [ "sudo" ]; };
}
