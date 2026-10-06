{ lib, ... }:

{
  imports = [ ./graphical.nix ];

  bresilla.features.network.wireNames.enable = lib.mkDefault true;
  bresilla.features.system.laptopPower.enable = lib.mkDefault true;
  bresilla.features.system.tlp.enable = lib.mkDefault true;
  bresilla.features.system.yubikey.enable = lib.mkDefault true;
  bresilla.features.system.fingerprint.enable = lib.mkDefault true;
  bresilla.features.system.hardwareDev.enable = lib.mkDefault true;
  services.hardware.bolt.enable = lib.mkDefault true;
}
