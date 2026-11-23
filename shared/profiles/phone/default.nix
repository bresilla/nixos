{ config, lib, pkgs, ... }:
{
  # A touch phone with a modem: everything a phone has is listed here, nothing is inherited.
  imports = [ ./windows.nix ];
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  nix.settings.max-jobs = lib.mkDefault 1;
  nix.settings.cores = lib.mkDefault 2;
  services.smartd.enable = false;
  bresilla.programs.agents.enable = false;

  programs.eva.enable = true;
  programs.eva.phone.enable = true;
  programs.eva.phone.gestureDriver = "native";

  bresilla.features.desktop.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.jack.enable = lib.mkDefault true;
  bresilla.features.desktop.flatpak.enable = lib.mkDefault true;
  environment.systemPackages = [ pkgs.chromium ];
  bresilla.programs.flatpak.everyday.enable = true;
  bresilla.programs.flatpak.defaultBrowser = "app.zen_browser.zen";

  bresilla.features.network.cellular.enable = lib.mkDefault true;
  bresilla.features.network.bluetooth.enable = lib.mkDefault true;
  bresilla.features.network.wifi.enable = lib.mkDefault true;
  bresilla.system.remote.ssh.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "client";
  bresilla.services.vpnClients.mullvad.enable = lib.mkDefault true;
  bresilla.features.system.uinput.enable = lib.mkDefault true;
  bresilla.features.system.fingerprint.enable = lib.mkDefault true;
  bresilla.features.system.usbSignaller.enable = lib.mkDefault true;
  bresilla.features.system.chargeLimit = lib.mkDefault 80;
  bresilla.programs.razerKishi.enable = lib.mkDefault true;
  services.accounts-daemon.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
  services.upower.enable = lib.mkDefault true;
  bresilla.programs.steamArm64 = {
    enable = lib.mkDefault true;
    session.enable = lib.mkDefault true;
    session.autoLogin = lib.mkDefault false;
  };
}
