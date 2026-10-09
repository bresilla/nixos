{ lib, ... }:

{
  programs.morf.enable = true;
  programs.morf.pattern.enable = false;
  programs.morf.usePackagedTheme = true;

  bresilla.features.network.cellular.enable = lib.mkDefault true;
  bresilla.features.desktop.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.jack.enable = lib.mkDefault true;
  bresilla.features.desktop.flatpak.enable = lib.mkDefault true;
  bresilla.programs.flatpak.apps = [
    "com.github.tchx84.Flatseal"
    "org.mozilla.firefox"
    "app.zen_browser.zen"
  ];
  xdg.mime.defaultApplications = lib.genAttrs [
    "text/html"
    "application/xhtml+xml"
    "x-scheme-handler/http"
    "x-scheme-handler/https"
    "x-scheme-handler/about"
    "x-scheme-handler/unknown"
  ] (_: "app.zen_browser.zen.desktop");
  bresilla.features.network.bluetooth.enable = lib.mkDefault true;
  bresilla.features.network.wifi.enable = lib.mkDefault true;
  bresilla.features.system.ssh.enable = lib.mkDefault true;
  bresilla.features.system.uinput.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "client";
  bresilla.services.vpnClients.mullvad.enable = lib.mkDefault true;
  services.accounts-daemon.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
  services.upower.enable = lib.mkDefault true;
}
