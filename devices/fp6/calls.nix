{
  config,
  lib,
  pkgs,
  ...
}:
let
  imsd = pkgs.callPackage ./packages/imsd.nix { };
  # The native IMS media process uses the HiFi speakers/microphone. This
  # board currently has no separate ALSA earpiece port; retain that route.
  callaudiod = pkgs.callaudiod.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/cad-pulse.c \
        --replace-fail 'if (!has_speaker || !has_earpiece)' 'if (!has_speaker)'
    '';
  });
in
lib.mkIf config.networking.modemmanager.enable {
  environment.systemPackages = [
    imsd
    pkgs.calls
  ];
  services.dbus.packages = [
    imsd
    callaudiod
  ];
  boot.kernelModules = [
    "xfrm_user"
    "esp4"
    "esp6"
  ];

  programs.dconf.profiles.user.databases = [
    {
      # ModemManager's circuit-switched voice path has no audio on this board.
      settings."org/gnome/Calls".autoload-plugins = [ "ofono" ];
    }
  ];
  # Calls supplies an XDG autostart entry using --gapplication-service.
  # A second service would compete with it; Calls 50 also removed --daemon.

  # SIP after IPsec decapsulation and RTP are admitted only on modem mux
  # interfaces. The bring-up script's pmOS firewall edits do not apply here.
  networking.firewall.extraInputRules = ''
    iifname "qmapmux*" meta l4proto esp accept comment "FP6 IMS IPsec"
    iifname "qmapmux*" tcp dport 45061-45062 accept comment "FP6 IMS signalling"
    iifname "qmapmux*" udp dport { 45061-45062, 50004 } accept comment "FP6 IMS signalling and media"
  '';
  systemd.services.imsd = {
    description = "FP6 IMS/VoLTE calling";
    # Carrier registration can take minutes. The timer starts this outside
    # graphical.target's dependency chain, which UWSM waits for at login.
    wants = [ "ModemManager.service" ];
    after = [
      "ModemManager.service"
      "network.target"
    ];
    path = [
      config.networking.modemmanager.package
      pkgs.libqmi
      pkgs.iproute2
      pkgs.nftables
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.gawk
      pkgs.systemd
      pkgs.util-linux
      pkgs.sudo
    ];
    serviceConfig = {
      ExecStartPre = "${imsd}/libexec/ims-pdn-up.sh";
      ExecStart = "${imsd}/bin/imsd";
      EnvironmentFile = [
        "-/run/imsd.env"
        "-/etc/imsd.env"
      ];
      StateDirectory = "imsd";
      StateDirectoryMode = "0700";
      TimeoutStartSec = 900;
      Restart = "on-failure";
      RestartSec = 120;
      KillMode = "mixed";
      TimeoutStopSec = 10;
    };
  };
  systemd.timers.imsd = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnBootSec = "20s";
  };
  systemd.services.imsd-ofonod = {
    description = "FP6 IMS backend for Calls";
    wantedBy = [ "multi-user.target" ];
    conflicts = [ "ofono.service" ];
    serviceConfig = {
      ExecStart = "${imsd}/bin/imsd-ofonod";
      EnvironmentFile = "-/etc/imsd.env";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
