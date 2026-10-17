{ lib, ... }:
{
  imports = [
    ./hardware.nix
    ./boot.nix
    ./storage.nix
    ./fan.nix
    ./usb-gadget.nix
    ./display.nix
  ];
  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "odin3";

  # As on the FP6: Qualcomm ath Wi-Fi joins through wpa_supplicant, not iwd.
  networking.networkmanager.wifi.backend = "wpa_supplicant";
  networking.networkmanager.logLevel = "INFO";
  # The kernel lacks the nftables FIB matcher the reverse-path filter uses.
  networking.firewall.checkReversePath = lib.mkForce false;
  # NetworkManager owns the network; networkd has no links to wait for.
  systemd.network.wait-online.enable = false;
  # Kernels are cross-compiled elsewhere and copied in, which needs a trusted user.
  nix.settings.trusted-users = [ "@wheel" ];
}
