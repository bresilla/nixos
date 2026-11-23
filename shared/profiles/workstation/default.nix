{ config, lib, pkgs, ... }:

{
  # Plugged in and headless: it boots to a console and serves its desktop over RDP.
  # Everything a workstation has is listed here, nothing is inherited.
  programs.eva.enable = true;
  programs.eva.idle = {
    lockTimeout = 1800;
    suspendTimeout = 0;
  };

  # The desktop runs only as the remote session.
  bresilla.system.remote.headless = true;

  bresilla.features.desktop.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.jack.enable = lib.mkDefault true;
  bresilla.features.desktop.flatpak.enable = lib.mkDefault true;
  environment.systemPackages = [ pkgs.chromium ];
  # Edge, Spotify, Steam Link and Blender are on Flathub for x86_64 only.
  bresilla.programs.flatpak.everyday.enable = true;
  bresilla.programs.flatpak.apps = lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
    "com.microsoft.EdgeDev"
    "com.spotify.Client"
    "com.valvesoftware.SteamLink"
    "org.blender.Blender"
  ];
  bresilla.programs.flatpak.defaultBrowser = "app.zen_browser.zen";

  # A local Ollama on the GPU, through Vulkan: cached for x86 and ARM, unlike the CUDA build.
  # Other machines reach it over NetBird only.
  services.ollama = {
    enable = true;
    package = pkgs.ollama-vulkan;
    host = "0.0.0.0";
  };
  networking.firewall.interfaces.netbird0.allowedTCPPorts = [ 11434 ];
  environment.sessionVariables.OLLAMA_HOST = "127.0.0.1:11434";
  # Isaac Sim ships for x86_64 only.
  bresilla.programs.isaacsim.enable = lib.mkDefault pkgs.stdenv.hostPlatform.isx86_64;
  # An x86_64 workstation builds images for the ARM devices under emulation.
  boot.binfmt.emulatedSystems = lib.optional pkgs.stdenv.hostPlatform.isx86_64 "aarch64-linux";

  bresilla.features.network.bluetooth.enable = lib.mkDefault true;
  bresilla.features.network.wifi.enable = lib.mkDefault true;
  bresilla.features.network.wireNames.enable = lib.mkDefault true;
  bresilla.features.network.phoneUsbShare.enable = lib.mkDefault true;
  bresilla.system.remote.ssh.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "client";
  bresilla.services.spotifyd.enable = lib.mkDefault true;
  bresilla.services.lan-mouse.enable = lib.mkDefault true;
  bresilla.features.system.uinput.enable = lib.mkDefault true;
  bresilla.features.system.hardwareDev.enable = lib.mkDefault true;
  bresilla.features.system.virtualisation.enable = lib.mkDefault true;
  services.hardware.bolt.enable = lib.mkDefault true;
  services.accounts-daemon.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
  services.upower.enable = lib.mkDefault true;
}
