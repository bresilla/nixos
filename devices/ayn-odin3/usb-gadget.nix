{ config, lib, pkgs, ... }:
let
  device = "02:00:00:00:03:01";
  host = "02:00:00:00:03:02";
  signaller = config.bresilla.features.system.usbSignaller.enable;
in
{
  # The role switch keeps the host default from the device tree; usb-signaller
  # sets it from the Type-C data role instead.
  bresilla.features.system.usbSignaller.roleFromTypec = true;

  # NCM networking over USB-C, as on the FP6, when usb-signaller is off. The
  # controller offers a device side only while the port is not a host, so udev
  # starts this when it appears.
  boot.kernelModules = [ "libcomposite" ];
  services.udev.extraRules = lib.mkIf (!signaller) ''
    ACTION=="add", SUBSYSTEM=="udc", TAG+="systemd", ENV{SYSTEMD_WANTS}+="odin3-usb-gadget.service"
  '';
  systemd.services.odin3-usb-gadget = lib.mkIf (!signaller) {
    description = "Odin 3 USB NCM networking";
    after = [ "sys-kernel-config.mount" ];
    requires = [ "sys-kernel-config.mount" ];
    path = [ pkgs.coreutils ];
    # Not kept active, so the next device-mode switch binds it again.
    serviceConfig.Type = "oneshot";
    script = ''
      gadget=/sys/kernel/config/usb_gadget/odin3
      mkdir -p "$gadget"
      if [ -n "$(cat "$gadget/UDC" 2>/dev/null)" ]; then exit 0; fi
      echo 0x1d6b > "$gadget/idVendor"
      echo 0x0103 > "$gadget/idProduct"
      mkdir -p "$gadget/strings/0x409" "$gadget/configs/c.1/strings/0x409"
      echo odin3-nixos > "$gadget/strings/0x409/serialnumber"
      echo AYN > "$gadget/strings/0x409/manufacturer"
      echo 'NixOS Odin 3 USB networking' > "$gadget/strings/0x409/product"
      echo 'NCM networking' > "$gadget/configs/c.1/strings/0x409/configuration"
      mkdir -p "$gadget/functions/ncm.usb0"
      echo ${device} > "$gadget/functions/ncm.usb0/dev_addr"
      echo ${host} > "$gadget/functions/ncm.usb0/host_addr"
      if [ ! -L "$gadget/configs/c.1/ncm.usb0" ]; then
        ln -s "$gadget/functions/ncm.usb0" "$gadget/configs/c.1/ncm.usb0"
      fi
      for controller in /sys/class/udc/*; do
        [ -e "$controller" ] && basename "$controller" > "$gadget/UDC" && exit 0
      done
    '';
  };

  # The computer on USB shares its connection; it ranks after Wi-Fi. Both
  # gadgets name the interface usb0; usb-signaller's MAC is random.
  systemd.network.networks."10-odin3-usb" = {
    matchConfig.Name = "usb0";
    networkConfig.DHCP = "ipv4";
    dhcpV4Config.RouteMetric = 650;
    linkConfig.RequiredForOnline = "no";
  };
  networking.networkmanager.unmanaged = [ "interface-name:usb0" ];
}
