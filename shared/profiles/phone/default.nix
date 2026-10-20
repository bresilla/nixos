{ config, lib, ... }:
{
  # A touch phone with a modem: everything a phone has is listed here, nothing is inherited.
  imports = [ ./windows.nix ];
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  nix.settings.max-jobs = lib.mkDefault 1;
  nix.settings.cores = lib.mkDefault 2;
  services.smartd.enable = false;
  bresilla.programs.agents.enable = false;

  programs.eva.enable = true;
  programs.eva.pattern.enable = false;
  programs.eva.usePackagedShell = true;
  programs.eva.phone.enable = true;
  programs.eva.phone.gestureDriver = "native";
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

  bresilla.features.desktop.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.jack.enable = lib.mkDefault true;
  bresilla.features.desktop.flatpak.enable = lib.mkDefault true;
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
  ];
  xdg.mime.defaultApplications = lib.genAttrs [
    "text/html"
    "application/xhtml+xml"
    "x-scheme-handler/http"
    "x-scheme-handler/https"
    "x-scheme-handler/about"
    "x-scheme-handler/unknown"
  ] (_: "app.zen_browser.zen.desktop");

  bresilla.features.network.cellular.enable = lib.mkDefault true;
  bresilla.features.network.bluetooth.enable = lib.mkDefault true;
  bresilla.features.network.wifi.enable = lib.mkDefault true;
  bresilla.system.remote.ssh.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "client";
  bresilla.services.vpnClients.mullvad.enable = lib.mkDefault true;
  bresilla.features.system.uinput.enable = lib.mkDefault true;
  bresilla.features.system.fingerprint.enable = lib.mkDefault true;
  services.accounts-daemon.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
  services.upower.enable = lib.mkDefault true;
}
