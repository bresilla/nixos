{ lib, pkgs, ... }:

{
  imports = [ ../shared.nix ];

  programs.morf.idle = {
    lockTimeout = 1800;
    suspendTimeout = 0;
  };

  # Flathub ships these for x86_64 only, so ARM machines (lama, the phone) skip them.
  bresilla.programs.flatpak.apps = lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
    "com.microsoft.EdgeDev"
    "com.spotify.Client"
    "com.valvesoftware.SteamLink"
  ];

  bresilla.services.spotifyd.enable = lib.mkDefault true;
  bresilla.services.wifiman.enable = lib.mkDefault true;
  bresilla.features.network.wireNames.enable = lib.mkDefault true;
  bresilla.features.network.phoneUsbShare.enable = lib.mkDefault true;
  bresilla.features.system.laptopPower.enable = lib.mkDefault true;
  bresilla.features.system.tlp.enable = lib.mkDefault true;
  bresilla.features.system.yubikey.enable = lib.mkDefault true;
  bresilla.features.system.fingerprint.enable = lib.mkDefault true;
  bresilla.features.system.hardwareDev.enable = lib.mkDefault true;
  bresilla.features.system.virtualisation.enable = lib.mkDefault true;
  services.hardware.bolt.enable = lib.mkDefault true;
}
