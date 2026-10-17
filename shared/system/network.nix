{
  config,
  lib,
  pkgs,
  modemmanagerSource,
  libqmiSource,
  ...
}:
let
  cfg = config.bresilla.features;
  sourceVersion =
    tree:
    builtins.head (
      builtins.match ".*\n  version: '([^']+)'.*" (builtins.readFile (tree + "/meson.build"))
    );
  version = sourceVersion modemmanagerSource;
  qmiVersion = sourceVersion libqmiSource;
  qmi =
    if lib.versionAtLeast pkgs.libqmi.version qmiVersion then
      pkgs.libqmi
    else
      pkgs.libqmi.overrideAttrs {
        version = qmiVersion;
        src = libqmiSource;
      };
  modemPackage =
    # Stable nixpkgs currently lacks XMM7360 RPC support and recent QRTR fixes.
    # The installer refreshes this upstream input along with the other software.
    if lib.versionAtLeast pkgs.modemmanager.version version then
      pkgs.modemmanager
    else
      (pkgs.modemmanager.override { libqmi = qmi; }).overrideAttrs {
        inherit version;
        src = modemmanagerSource;
      };
in
{
  options.bresilla.features.network = {
    networkmanager.enable = lib.mkEnableOption "NetworkManager";
    cellular.enable = lib.mkEnableOption "current ModemManager cellular hardware support";
    bluetooth.enable = lib.mkEnableOption "Bluetooth";
    wifi = {
      enable = lib.mkEnableOption "Wi-Fi support";
      powersave = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable NetworkManager Wi-Fi powersave.";
      };
    };
    wireNames.enable = lib.mkEnableOption "wireX names for physical Ethernet interfaces";
    phoneUsbShare.enable = lib.mkEnableOption "sharing this computer's internet with the FP6 and Odin 3 over USB";
  };
  config = lib.mkMerge [
    {
      bresilla.features.network.networkmanager.enable = lib.mkDefault true;
      networking.firewall.enable = true;
      networking.nftables.enable = true;
      networking.enableIPv6 = true;
      services.rpcbind.enable = true;
      services.avahi = {
        enable = true;
        nssmdns4 = true;
        nssmdns6 = true;
      };
    }

    (lib.mkIf cfg.network.networkmanager.enable {
      networking.networkmanager.enable = true;
    })

    (lib.mkIf cfg.network.wifi.enable {
      networking.networkmanager.wifi.backend = lib.mkDefault "iwd";
      networking.networkmanager.wifi.powersave = cfg.network.wifi.powersave;
    })

    (lib.mkIf cfg.network.wireNames.enable {
      systemd.network.links."10-wire" = {
        matchConfig.Type = "ether";
        # Physical NICs only: ZeroTier taps and libvirt bridges are ether too.
        matchConfig.Path = "pci-* platform-*";
        linkConfig.NamePolicy = "path";
        linkConfig.Name = "wire";
      };
    })

    # The FP6 USB gadget always gives this end 02:00:00:00:06:02. NetworkManager
    # shares the connection there: DHCP, DNS and NAT for the phone.
    (lib.mkIf cfg.network.phoneUsbShare.enable {
      systemd.network.links."05-fp6-usb" = {
        matchConfig.MACAddress = "02:00:00:00:06:02";
        linkConfig.Name = "fair0";
      };
      networking.networkmanager.ensureProfiles.profiles.fp6-usb = {
        connection = {
          id = "fp6-usb";
          type = "ethernet";
          interface-name = "fair0";
          autoconnect = "true";
        };
        ethernet = { };
        ipv4.method = "shared";
        ipv6.method = "link-local";
      };
      systemd.network.links."05-odin3-usb" = {
        matchConfig.MACAddress = "02:00:00:00:03:02";
        linkConfig.Name = "odin0";
      };
      networking.networkmanager.ensureProfiles.profiles.odin3-usb = {
        connection = {
          id = "odin3-usb";
          type = "ethernet";
          interface-name = "odin0";
          autoconnect = "true";
        };
        ethernet = { };
        ipv4.method = "shared";
        ipv6.method = "link-local";
      };
      networking.firewall.trustedInterfaces = [ "fair0" "odin0" ];
    })

    (lib.mkIf cfg.network.bluetooth.enable {
      hardware.bluetooth.enable = true;
      services.blueman.enable = true;
    })

    (lib.mkIf cfg.network.cellular.enable {
      networking.modemmanager.enable = lib.mkDefault true;
      networking.modemmanager.package = modemPackage;
      # Start the observer even before a desktop client asks for the bus name.
      systemd.services.ModemManager.wantedBy = lib.mkIf config.networking.modemmanager.enable [
        "multi-user.target"
      ];
    })
  ];
}
