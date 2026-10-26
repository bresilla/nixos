{
  config,
  lib,
  pkgs,
  bresilla,
  ...
}:
let
  cfg = config.bresilla.features.system.usbSignaller;
  package = bresilla.usb-signaller or (pkgs.callPackage ../../packages/usb-signaller.nix { });
  # The NCM gadget's interface; networkd matches it by name in either mode.
  iface = "usb0";
  tethering = pkgs.writeText "05-usb-tethering.network" ''
    [Match]
    Name=${iface}

    [Network]
    Address=172.16.42.1/24
    DHCPServer=yes
    IPMasquerade=ipv4

    [DHCPServer]
    DNS=1.1.1.1 1.0.0.1
  '';
  usb-mode = pkgs.writeShellApplication {
    name = "usb-mode";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      bus=(com.meego.usb_moded /com/meego/usb_moded com.meego.usb_moded)
      case "''${1:-}" in
        "") busctl call "''${bus[@]}" mode_request ;;
        list) busctl call "''${bus[@]}" get_modes ;;
        *) busctl call "''${bus[@]}" set_mode s "$1" ;;
      esac
    '';
  };
in
{
  options.bresilla.features.system.usbSignaller.enable =
    lib.mkEnableOption "usb-signaller USB modes: developer (internet from the computer) and tethering";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ usb-mode ];
    systemd.packages = [ package ];
    services.dbus.packages = [ package ];
    # Developer mode on boot keeps today's behaviour: the computer shares its connection.
    environment.etc."usb-signaller/usb-signaller.toml".text = ''
      [main]
      default_mode = "developer_mode"
    '';

    systemd.services.usb-signaller = {
      wantedBy = [ "multi-user.target" ];
      after = [ "dbus.service" ];
      path = [ pkgs.util-linux ];
    };

    # Called by usb-signaller on each mode switch. Developer mode is the device's own
    # networkd DHCP client on usb0; tethering overlays a DHCP server with NAT on top.
    systemd.services.usb-signaller-developer-mode = {
      description = "USB developer mode";
      path = [ pkgs.systemd ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "networkctl reconfigure ${iface} || true";
    };
    systemd.services.usb-signaller-tethering-mode = {
      description = "USB tethering mode";
      path = [ pkgs.systemd pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -Dm644 ${tethering} /run/systemd/network/05-usb-tethering.network
        networkctl reload
        networkctl reconfigure ${iface} || true
        echo 1 > /proc/sys/net/ipv4/ip_forward
      '';
      # usb-signaller reads ip_forward to tell tethering from developer mode.
      preStop = ''
        rm -f /run/systemd/network/05-usb-tethering.network
        networkctl reload
        echo 0 > /proc/sys/net/ipv4/ip_forward
        networkctl reconfigure ${iface} || true
      '';
    };
    networking.firewall.interfaces.${iface}.allowedUDPPorts = [ 67 ];
  };
}
