{ lib, ... }:
{
  imports = [
    ./storage.nix
    ../../device-recipes/lenovo-tb321fu/software/hardware.nix
    ../../device-recipes/lenovo-tb321fu/software/boot.nix
    ../../device-recipes/lenovo-tb321fu/software/usb-gadget.nix
    ../../device-recipes/lenovo-tb321fu/software/display.nix
    ../../device-recipes/lenovo-tb321fu/software/pen.nix
    ../../device-recipes/lenovo-tb321fu/software/audio.nix
    ../../device-recipes/lenovo-tb321fu/software/suspend.nix
    ../../device-recipes/lenovo-tb321fu/software/battery-log.nix
  ];
  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "lego";
  bresilla.nix.buildOnTron = true;

  # A phone without the phone parts: no modem, no fingerprint reader.
  bresilla.features.network.cellular.enable = false;
  bresilla.features.system.fingerprint.enable = false;

  # As on the Odin 3: Qualcomm ath Wi-Fi joins through wpa_supplicant, not iwd.
  networking.networkmanager.wifi.backend = "wpa_supplicant";
  networking.networkmanager.logLevel = "INFO";
  # The kernel lacks the nftables FIB matcher the reverse-path filter uses.
  networking.firewall.checkReversePath = lib.mkForce false;
  # NetworkManager owns the network; networkd has no links to wait for.
  systemd.network.wait-online.enable = false;
  # The sensor hub is not ported, and the iio module wants hid-sensor-hub in the initrd.
  hardware.sensor.iio.enable = lib.mkForce false;
}
