{ lib, ... }:
{
  imports = [
    ./hardware.nix
    ./touchscreen.nix
    ./modem.nix
  ];
  nixpkgs.config.allowUnfree = true;
  programs.morf.phone.idleTimeout = 0;
  programs.morf.uiScale = 1.8;

  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = lib.mkDefault "fp6";
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
  networking.firewall.interfaces.usb0.allowedUDPPorts = [ 67 ];
  systemd.network.networks."10-fp6-usb" = {
    matchConfig.Name = "usb0";
    address = [ "10.42.0.1/24" ];
    networkConfig.DHCPServer = true;
    dhcpServerConfig = {
      EmitRouter = false;
      EmitDNS = false;
    };
    linkConfig.RequiredForOnline = "no";
  };
  # NetworkManager may manage Wi-Fi; USB remains under systemd-networkd.
  networking.networkmanager.unmanaged = [ "interface-name:usb0" ];
  # IWD fails to discover hidden networks on this Wi-Fi hardware. The same
  # network authenticates with wpa_supplicant, managed normally by NM.
  networking.networkmanager.wifi.backend = "wpa_supplicant";
  # Not enabled in the upstream device kernel.
  security.apparmor.enable = false;
}
