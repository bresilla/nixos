{ lib, ... }:

{
  imports = [ ./shared/desktop.nix ];

  programs.morf.idle = {
    lockTimeout = 1800;
    suspendTimeout = 0;
  };

  # Flathub ships these for x86_64 only, so they stay off the phone.
  bresilla.programs.flatpak.apps = [
    "com.microsoft.EdgeDev"
    "com.spotify.Client"
  ];

  bresilla.features.network.wireNames.enable = lib.mkDefault true;
  bresilla.features.system.laptopPower.enable = lib.mkDefault true;
  bresilla.features.system.tlp.enable = lib.mkDefault true;
  bresilla.features.system.yubikey.enable = lib.mkDefault true;
  bresilla.features.system.fingerprint.enable = lib.mkDefault true;
  bresilla.features.system.hardwareDev.enable = lib.mkDefault true;
  services.hardware.bolt.enable = lib.mkDefault true;
}
