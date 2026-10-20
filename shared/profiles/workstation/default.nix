{ config, lib, pkgs, ... }:

{
  # Plugged in and headless: it boots to a console and serves its desktop over RDP.
  # Everything a workstation has is listed here, nothing is inherited.
  programs.eva.enable = true;
  programs.eva.pattern.enable = false;
  programs.eva.usePackagedShell = true;
  programs.eva.idle = {
    lockTimeout = 1800;
    suspendTimeout = 0;
  };
  # Morf keys settings by the theme's store path; keep one file across updates.
  systemd.user.services.morf.environment.EVA_SETTINGS = lib.mkDefault "%h/.local/state/morf/eva.json";
  # The settings from before eva was named, carried over once.
  systemd.user.services.morf.preStart = ''
    if [ ! -e "$HOME/.local/state/morf/eva.json" ] && [ -e "$HOME/.local/state/morf/caelestia.json" ]; then
      cp -p "$HOME/.local/state/morf/caelestia.json" "$HOME/.local/state/morf/eva.json"
    fi
  '';
  # Apps started from Morf inherit its PATH; a login's one lets them find setuid sudo.
  systemd.user.services.morf.environment.PATH = lib.mkForce (lib.concatStringsSep ":" [
    "/run/wrappers/bin"
    "/etc/profiles/per-user/${config.bresilla.user.name}/bin"
    "/nix/var/nix/profiles/default/bin"
    "/run/current-system/sw/bin"
    "/run/current-system/sw/sbin"
  ]);

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
  # The last three come from Flathub for x86_64 only, so ARM workstations skip them.
  bresilla.programs.flatpak.apps = [
    "com.github.tchx84.Flatseal"
    "org.mozilla.firefox"
    "app.zen_browser.zen"
    "org.chromium.Chromium"
    "net.lockbook.Lockbook"
    "com.anydesk.Anydesk"
    "com.rustdesk.RustDesk"
    "com.freerdp.FreeRDP"
    "com.moonlight_stream.Moonlight"
    "org.zotero.Zotero"
  ] ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
    "com.microsoft.EdgeDev"
    "com.spotify.Client"
    "com.valvesoftware.SteamLink"
  ];
  xdg.mime.defaultApplications = lib.genAttrs [
    "text/html"
    "application/xhtml+xml"
    "x-scheme-handler/http"
    "x-scheme-handler/https"
    "x-scheme-handler/about"
    "x-scheme-handler/unknown"
  ] (_: "app.zen_browser.zen.desktop");

  # A local Ollama on the GPU, through Vulkan: cached for x86 and ARM, unlike the CUDA build.
  # It listens everywhere, but only the trusted NetBird interface lets other machines in.
  services.ollama = {
    enable = true;
    package = pkgs.ollama-vulkan;
    host = "0.0.0.0";
  };
  environment.sessionVariables.OLLAMA_HOST = "127.0.0.1:11434";
  bresilla.programs.isaacsim.enable = lib.mkDefault true;
  # Builds images for the ARM devices (phone, Odin 3) under emulation.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  bresilla.features.network.cellular.enable = lib.mkDefault true;
  bresilla.features.network.bluetooth.enable = lib.mkDefault true;
  bresilla.features.network.wifi.enable = lib.mkDefault true;
  bresilla.features.network.wireNames.enable = lib.mkDefault true;
  bresilla.features.network.phoneUsbShare.enable = lib.mkDefault true;
  bresilla.system.remote.ssh.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "client";
  bresilla.services.vpnClients.mullvad.enable = lib.mkDefault true;
  bresilla.services.spotifyd.enable = lib.mkDefault true;
  bresilla.services.wifiman.enable = lib.mkDefault true;
  bresilla.features.system.uinput.enable = lib.mkDefault true;
  bresilla.features.system.yubikey.enable = lib.mkDefault true;
  bresilla.features.system.fingerprint.enable = lib.mkDefault true;
  bresilla.features.system.hardwareDev.enable = lib.mkDefault true;
  bresilla.features.system.virtualisation.enable = lib.mkDefault true;
  services.hardware.bolt.enable = lib.mkDefault true;
  services.accounts-daemon.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
  services.upower.enable = lib.mkDefault true;
}
