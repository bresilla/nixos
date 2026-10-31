{ lib, ... }:
{
  imports = [
    ./storage.nix
    ../../device-recipes/ayn-odin3/software/hardware.nix
    ../../device-recipes/ayn-odin3/software/boot.nix
    ../../device-recipes/ayn-odin3/software/fan.nix
    ../../device-recipes/ayn-odin3/software/usb-gadget.nix
    ../../device-recipes/ayn-odin3/software/display.nix
    ../../device-recipes/ayn-odin3/software/audio.nix
    ../../device-recipes/ayn-odin3/software/suspend.nix
  ];
  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "odin";
  bresilla.nix.buildOnTron = true;

  # As on the FP6: Qualcomm ath Wi-Fi joins through wpa_supplicant, not iwd.
  networking.networkmanager.wifi.backend = "wpa_supplicant";
  networking.networkmanager.logLevel = "INFO";
  # The kernel lacks the nftables FIB matcher the reverse-path filter uses.
  networking.firewall.checkReversePath = lib.mkForce false;
  # NetworkManager owns the network; networkd has no links to wait for.
  systemd.network.wait-online.enable = false;
}
