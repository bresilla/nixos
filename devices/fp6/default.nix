{ lib, ... }:
{
  imports = [
    ./hardware.nix
    ./touchscreen.nix
    ./rotation.nix
    ./audio.nix
    ./modem.nix
    ./calls.nix
    ./fingerprint.nix
  ];
  nixpkgs.config.allowUnfree = true;
  programs.morf.phone.idleTimeout = 0;
  programs.morf.uiScale = 1.8;

  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "fp6";
  networking.useDHCP = false;
  networking.useNetworkd = true;
  # Networkd only owns optional USB tethering. NetworkManager owns the
  # internet connection, so networkd must not hold up graphical activation.
  systemd.network.wait-online.enable = false;
  networking.usePredictableInterfaceNames = false;
  networking.nftables.enable = true;
  # The upstream FP6 kernel has nftables, but lacks the iptables pkttype
  # matcher and the NFT_FIB_INET module used for reverse-path filtering.
  networking.firewall.checkReversePath = lib.mkForce false;
  # A computer on USB shares its connection: it ranks after Wi-Fi (600) and
  # before mobile data (700). Link-local IPv6 keeps SSH working without it.
  systemd.network.networks."10-fp6-usb" = {
    matchConfig.Name = "usb0";
    networkConfig.DHCP = "ipv4";
    dhcpV4Config.RouteMetric = 650;
    linkConfig.RequiredForOnline = "no";
  };
  # NetworkManager may manage Wi-Fi; USB remains under systemd-networkd.
  networking.networkmanager.unmanaged = [ "interface-name:usb0" ];
  # iwd's probes never reveal hidden networks on this ath11k Wi-Fi, though the
  # driver answers plain ones; wpa_supplicant joins them, managed by NM.
  networking.networkmanager.wifi.backend = "wpa_supplicant";
}
