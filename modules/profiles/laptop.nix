{ lib, ... }:

{
  bresilla.features.desktop.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.jack.enable = lib.mkDefault true;
  bresilla.features.desktop.flatpak.enable = lib.mkDefault true;
  bresilla.programs.flatpak.apps = [
    "com.github.tchx84.Flatseal"
    "org.mozilla.firefox"
  ];
  bresilla.features.network.bluetooth.enable = lib.mkDefault true;
  bresilla.features.network.wifi.enable = lib.mkDefault true;
  bresilla.features.network.wireNames.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "client";
  bresilla.features.system.laptopPower.enable = lib.mkDefault true;
  bresilla.features.system.tlp.enable = lib.mkDefault true;
  bresilla.features.system.uinput.enable = lib.mkDefault true;
  bresilla.features.system.yubikey.enable = lib.mkDefault true;
  bresilla.features.system.hardwareDev.enable = lib.mkDefault true;
  bresilla.services.vpnClients.mullvad.enable = lib.mkDefault true;
  services.accounts-daemon.enable = lib.mkDefault true;
  services.hardware.bolt.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
  services.upower.enable = lib.mkDefault true;
}
