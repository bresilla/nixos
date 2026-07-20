# The file the disko CLI applies during installation. Translates the LIS
# document (generated/system.lis.json — the ONLY thing the installer emits)
# into disko devices at evaluation time.
{ lib, ... }:

{
  disko.devices = import ./to-disko.nix {
    inherit lib;
    doc = builtins.fromJSON (builtins.readFile ../generated/system.lis.json);
  };
}
