{ config, lib, pkgs, ... }:

{
  # Embedded boards and industrial PCs: headless, the desktop served over RDP, CAN bus tools.
  # Everything an iot machine has is listed here, nothing is inherited.
  programs.eva.enable = true;
  programs.eva.idle = {
    lockTimeout = 1800;
    suspendTimeout = 0;
  };

  # The desktop runs only as the remote session, started over SSH with `sudo hypr-remote start`.
  services.greetd.enable = lib.mkForce false;
  # Morf still adds wants to greetd.service; masking it keeps that stub from starting.
  systemd.services.greetd.enable = false;
  systemd.defaultUnit = lib.mkForce "multi-user.target";
  # Morf still gives the greeter a home; without greetd it needs to be a system user.
  users.users.greeter = {
    isSystemUser = true;
    group = "greeter";
  };
  users.groups.greeter = { };
  bresilla.system.remote.rdp = {
    enable = lib.mkDefault true;
    autoStart = lib.mkDefault false;
  };

  bresilla.features.desktop.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.jack.enable = lib.mkDefault true;
  bresilla.features.desktop.flatpak.enable = lib.mkDefault true;

  # CAN bus work: SocketCAN tools (candump, cansend, …) and cantools for DBC decoding.
  environment.systemPackages = [
    pkgs.can-utils
    pkgs.python3Packages.cantools
  ];

  bresilla.features.network.cellular.enable = lib.mkDefault true;
  bresilla.features.network.bluetooth.enable = lib.mkDefault true;
  bresilla.features.network.wifi.enable = lib.mkDefault true;
  bresilla.features.network.wireNames.enable = lib.mkDefault true;
  bresilla.features.network.phoneUsbShare.enable = lib.mkDefault true;
  bresilla.system.remote.ssh.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "client";
  # IoT boards run unattended: sudo without a password for wheel.
  security.sudo.wheelNeedsPassword = false;
  # No names for the VPN and VM hosts: IoT boards only need to reach what they are given.
  networking.extraHosts = lib.mkForce "";
  bresilla.features.system.uinput.enable = lib.mkDefault true;
  bresilla.features.system.hardwareDev.enable = lib.mkDefault true;
  services.hardware.bolt.enable = lib.mkDefault true;
  services.accounts-daemon.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
  services.upower.enable = lib.mkDefault true;
}
