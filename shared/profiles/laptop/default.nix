{ config, lib, pkgs, ... }:

{
  # A portable desktop on battery: everything a laptop has is listed here, nothing is inherited.
  programs.eva.enable = true;
  programs.eva.idle = {
    lockTimeout = 1800;
    suspendTimeout = 0;
  };

  # A new Lule wallpaper, and colors from it, every three minutes of the session.
  home-manager.users.${config.bresilla.user.name}.systemd.user.timers.lule-wallpaper = {
    Unit = {
      Description = "New Lule wallpaper every three minutes";
      PartOf = [ "graphical-session.target" ];
    };
    Timer = {
      OnActiveSec = "3min";
      OnUnitActiveSec = "3min";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };


  bresilla.features.desktop.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.enable = lib.mkDefault true;
  bresilla.features.desktop.audio.jack.enable = lib.mkDefault true;
  bresilla.features.desktop.flatpak.enable = lib.mkDefault true;
  environment.systemPackages = [ pkgs.chromium ];
  # Edge, Spotify, Steam Link and Blender are on Flathub for x86_64 only.
  bresilla.programs.flatpak.everyday.enable = true;
  bresilla.programs.flatpak.apps = [
    "org.libreoffice.LibreOffice"
    "org.inkscape.Inkscape"
  ] ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
    "com.microsoft.EdgeDev"
    "com.spotify.Client"
    "com.valvesoftware.SteamLink"
    "org.blender.Blender"
  ];
  bresilla.programs.flatpak.defaultBrowser = "app.zen_browser.zen";

  bresilla.features.network.cellular.enable = lib.mkDefault true;
  bresilla.features.network.bluetooth.enable = lib.mkDefault true;
  bresilla.features.network.wifi.enable = lib.mkDefault true;
  bresilla.features.network.wireNames.enable = lib.mkDefault true;
  bresilla.features.network.phoneUsbShare.enable = lib.mkDefault true;
  bresilla.system.remote.ssh.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "client";
  bresilla.services.vpnClients.mullvad.enable = lib.mkDefault true;
  bresilla.services.tunnels.mullvad.enable = lib.mkDefault true;
  bresilla.services.tunnels.tor.enable = lib.mkDefault true;
  bresilla.services.tunnels.teleport.enable = lib.mkDefault true;
  bresilla.services.tunnels.uni.enable = lib.mkDefault true;
  # WUR: its gateway and login, the home drive at /wur/M and the DFS root at /wur/W.
  bresilla.services.tunnels.uni.gateway = lib.mkDefault "mol02.wur.nl:443";
  bresilla.services.tunnels.uni.credentials = lib.mkDefault "/wur/access.creds";
  bresilla.services.tunnels.uni.drives = lib.mkDefault {
    M = { remote = ":smb,host=fs01mixedsmb.wurnet.nl:DBL-STANDARD_HOMEDIR$/@user@"; port = 8101; path = "/wur/M"; };
    W = { remote = ":smb,host=wurnet.nl:dfs-root"; port = 8102; path = "/wur/W"; };
  };
  bresilla.services.spotifyd.enable = lib.mkDefault true;
  bresilla.services.lan-mouse.enable = lib.mkDefault true;
  bresilla.services.wifiman.enable = lib.mkDefault true;
  bresilla.features.system.uinput.enable = lib.mkDefault true;
  bresilla.features.system.laptopPower.enable = lib.mkDefault true;
  bresilla.features.system.tlp.enable = lib.mkDefault true;
  bresilla.features.system.yubikey.enable = lib.mkDefault true;
  bresilla.features.system.fingerprint.enable = lib.mkDefault true;
  bresilla.features.system.hardwareDev.enable = lib.mkDefault true;
  bresilla.features.system.virtualisation.enable = lib.mkDefault true;
  services.hardware.bolt.enable = lib.mkDefault true;
  services.accounts-daemon.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
  services.upower.enable = lib.mkDefault true;
}
