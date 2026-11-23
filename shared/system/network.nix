{
  config,
  lib,
  pkgs,
  bresilla,
  ...
}:
let
  cfg = config.bresilla.features;
  modemPackage =
    # Upstream main from packages/, cached on cache.bresilla.com, until
    # nixpkgs ships 1.26 with XMM7360 RPC support and recent QRTR fixes.
    if lib.versionAtLeast pkgs.modemmanager.version "1.25.95" then
      pkgs.modemmanager
    else
      bresilla.modemmanager;
  # Each device's USB gadget, from its recipe: { host = { profile, mac, serial }; }.
  devices = ../../devices;
  gadgets = lib.concatMapAttrs (host: _:
    let
      info = devices + "/${host}/device.json";
      gadget = ../../device-recipes + "/${(lib.importJSON info).model or ""}/software/gadget.json";
    in lib.optionalAttrs (builtins.pathExists info && builtins.pathExists gadget) { ${host} = lib.importJSON gadget; })
    (lib.filterAttrs (_: type: type == "directory") (builtins.readDir devices));
  # A NetworkManager profile taking DHCP from a device's usb-signaller tethering.
  tethering = id: interface: {
    connection = {
      inherit id;
      type = "ethernet";
      interface-name = interface;
      autoconnect = "true";
    };
    ethernet = { };
    ipv4 = {
      method = "auto";
      route-metric = 650;
    };
    ipv6.method = "link-local";
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
      services.avahi = {
        enable = true;
        nssmdns4 = true;
        nssmdns6 = true;
        # Announce <hostname>.local; resolved's mDNS is off, so Avahi is the only responder.
        publish = {
          enable = true;
          addresses = true;
        };
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
      # Thunderbolt networking is ether on a PCI path too; it keeps its own name.
      systemd.network.links."09-thunderbolt" = {
        matchConfig.Driver = "thunderbolt-net";
        linkConfig.Name = "thunderbolt0";
      };
      systemd.network.links."10-wire" = {
        matchConfig.Type = "ether";
        # Physical NICs only: ZeroTier taps and libvirt bridges are ether too.
        matchConfig.Path = "pci-* platform-*";
        linkConfig.NamePolicy = "path";
        linkConfig.Name = "wire";
      };
    })

    # Each device whose recipe has software/gadget.json shares this computer's internet
    # over USB. In developer mode its gadget gives this end a fixed MAC: NetworkManager
    # serves it DHCP, DNS and NAT on <host>0. usb-signaller's gadgets get random MACs and
    # are told apart by the USB strings (the product names the mode, the serial the
    # model); in tethering mode, on <host>t0, the device shares its own connection.
    (lib.mkIf cfg.network.phoneUsbShare.enable {
      systemd.network.links = lib.mapAttrs' (host: g: lib.nameValuePair "05-${g.profile}-usb" {
        matchConfig.MACAddress = g.mac;
        linkConfig.Name = "${host}0";
      }) gadgets;
      networking.networkmanager.ensureProfiles.profiles = lib.concatMapAttrs (host: g: {
        "${g.profile}-usb" = {
          connection = {
            id = "${g.profile}-usb";
            type = "ethernet";
            interface-name = "${host}0";
            autoconnect = "true";
          };
          ethernet = { };
          ipv4.method = "shared";
          ipv6.method = "link-local";
        };
        "${g.profile}-tethering" = tethering "${g.profile}-tethering" "${host}t0";
      }) gadgets;
      services.udev.extraRules = lib.concatStrings (lib.mapAttrsToList (host: g: ''
        SUBSYSTEM=="net", ACTION=="add", ATTRS{serial}=="${g.serial}", ATTRS{product}=="*(developer)", NAME="${host}0"
        SUBSYSTEM=="net", ACTION=="add", ATTRS{serial}=="${g.serial}", ATTRS{product}=="*(tethering)", NAME="${host}t0"
      '') gadgets);
      # Only developer mode is trusted: this end serves it DHCP, DNS and NAT.
      networking.firewall.trustedInterfaces = map (host: "${host}0") (lib.attrNames gadgets);
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
