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
  # usb-mode points this link at the image to serve; the user owns the directory.
  image = "/var/lib/usb-signaller/image";
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
      # Serve a file read-only, as a CD-ROM (iso) or a USB stick (disk). A mode that is
      # already active is ignored, so charging_only comes first to pick up a new image.
      serve() {
        [ -f "$2" ] || { echo "usb-mode: no such file: $2" >&2; exit 1; }
        ln -sfn "$(realpath "$2")" ${image}
        busctl call "''${bus[@]}" set_mode s charging_only >/dev/null
        busctl call "''${bus[@]}" set_mode s "$1"
      }
      case "''${1:-}" in
        "") busctl call "''${bus[@]}" mode_request ;;
        list) busctl call "''${bus[@]}" get_modes ;;
        iso) serve cdrom_mode "''${2:?usb-mode iso <file>}" ;;
        disk) serve mass_storage_mode "''${2:?usb-mode disk <file>}" ;;
        *) busctl call "''${bus[@]}" set_mode s "$1" ;;
      esac
    '';
  };
in
{
  options.bresilla.features.system.usbSignaller = {
    enable = lib.mkEnableOption "usb-signaller USB modes: developer (internet from the computer) and tethering";
    roleFromTypec = lib.mkEnableOption ''
      taking the port's role from the Type-C data role, for role switches the
      Type-C controller does not drive: device on a computer, host otherwise'';
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ usb-mode ];
    systemd.packages = [ package ];
    services.dbus.packages = [ package ];
    # No default_mode: applying one forces the port to device role, which drops a
    # gamepad or other host-mode accessory plugged in at boot. usb-signaller-follow sets it.
    environment.etc."usb-signaller/usb-signaller.toml".text = ''
      [mass_storage]
      storage_path = "${image}"
    '';
    systemd.tmpfiles.rules = [ "d /var/lib/usb-signaller 0755 ${config.bresilla.user.name} users -" ];

    systemd.services.usb-signaller = {
      wantedBy = [ "multi-user.target" ];
      after = [ "dbus.service" ];
      path = [ pkgs.util-linux ];
    };

    # Developer mode whenever the port takes the device role (a computer on the cable),
    # unless another mode was chosen; a host role (an accessory) is left alone.
    services.udev.extraRules = ''
      ACTION=="change", SUBSYSTEM=="usb_role", TAG+="systemd", ENV{SYSTEMD_WANTS}+="usb-signaller-follow.service"
    '' + lib.optionalString cfg.roleFromTypec ''
      SUBSYSTEM=="typec", TAG+="systemd", ENV{SYSTEMD_WANTS}+="usb-signaller-follow.service"
    '';
    systemd.services.usb-signaller-follow = {
      description = "USB developer mode on the device role";
      wantedBy = [ "multi-user.target" ];
      after = [ "usb-signaller.service" ];
      requires = [ "usb-signaller.service" ];
      path = [ usb-mode pkgs.coreutils pkgs.gnugrep ];
      serviceConfig.Type = "oneshot";
      script = ''
        # usb-signaller registers on the bus a moment after it starts.
        for _ in $(seq 1 10); do usb-mode >/dev/null 2>&1 && break; sleep 1; done
        ${lib.optionalString cfg.roleFromTypec ''
          # The bracketed data role is the current one; a partner means a cable.
          if grep -qs '\[device\]' /sys/class/typec/port*/data_role && ls -d /sys/class/typec/*-partner >/dev/null 2>&1; then
            usb-mode | grep -qE 'charging_only|host_mode' && usb-mode developer_mode
          else
            usb-mode | grep -q host_mode || usb-mode host_mode
          fi
          exit 0
        ''}
        for role in /sys/class/usb_role/*/role; do
          [ "$(cat "$role")" = device ] || exit 0
        done
        usb-mode | grep -q charging_only && usb-mode developer_mode
        exit 0
      '';
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
