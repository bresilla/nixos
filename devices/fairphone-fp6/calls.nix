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
  # Under an IPv4-only attach the modem refuses an IPv6 ims request by APN
  # name, but not one through a stored profile. The profile persists in the
  # modem; add it once if the modem has none.
  imsProfile = pkgs.writeShellScript "fp6-ims-profile" ''
    mmcli=${config.networking.modemmanager.package}/bin/mmcli
    modem=$($mmcli -L | ${pkgs.gnused}/bin/sed -n 's,.*/Modem/\([0-9]*\) .*,\1,p' | ${pkgs.coreutils}/bin/head -n1)
    [ -n "$modem" ] || exit 0
    $mmcli -m "$modem" --3gpp-profile-manager-list | ${pkgs.gnugrep}/bin/grep -q "apn: ims$" ||
      $mmcli -m "$modem" --3gpp-profile-manager-set="profile-name=ims,apn=ims,ip-type=ipv6,apn-type=ims"
  '';
  # The modem throttles the APN after a network refusal. Count that as the
  # refusal it follows, so ten in a row idle imsd instead of retrying forever.
  # Patched outside the package, so the change does not recompile imsd.
  pdnUp = pkgs.runCommand "ims-pdn-up.sh" { } ''
    substitute ${imsd}/libexec/ims-pdn-up.sh $out \
      --replace-fail '|*MobileEquipment.Ipv6OnlyAllowed:*) PERSISTENT=1' '|*MobileEquipment.Ipv6OnlyAllowed:*|*Core.Throttled:*) PERSISTENT=1'
    chmod +x $out
  '';
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
      ExecStartPre = [
        "-${imsProfile}"
        "${pdnUp}"
      ];
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
