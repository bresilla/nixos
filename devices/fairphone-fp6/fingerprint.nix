{
  config,
  lib,
  pkgs,
  bresilla,
  ...
}:
let
  fingerprintd = bresilla.fingerprintd or (pkgs.callPackage ../../packages/fingerprintd.nix { });
  firmware = pkgs.callPackage ./packages/fingerprint-firmware.nix { };
  # Expose the standard clients and PAM module without installing the stock
  # daemon's competing D-Bus activation file or permissive enrollment policy.
  clients = pkgs.runCommand "fp6-fprintd-clients" { } ''
    mkdir -p "$out/bin" "$out/lib/security"
    for program in ${pkgs.fprintd}/bin/fprintd-*; do
      ln -s "$program" "$out/bin/"
    done
    ln -s ${pkgs.fprintd}/lib/security/pam_fprintd.so "$out/lib/security/"
  '';
in
{
  # The native daemon below replaces the profile's generic fprintd.
  bresilla.features.system.fingerprint.enable = false;
  assertions = [
    {
      assertion = !config.services.fprintd.enable;
      message = "FP6 uses its native fingerprintd; do not enable the competing stock fprintd service.";
    }
  ];
  environment.systemPackages = [
    fingerprintd
    clients
  ];
  services.dbus.packages = [ fingerprintd ];

  # Only fingerprintd pulls in this mount. It must use the original Android
  # persist partition: QTEE seals template containers to hardware counters.
  systemd.mounts = [
    {
      description = "FP6 fingerprint template storage";
      what = "/dev/disk/by-partlabel/persist";
      where = "/mnt/persist";
      type = "ext4";
      options = "rw,nosuid,nodev,noexec";
    }
  ];
  systemd.tmpfiles.rules = [
    "d /var/lib/fingerprintd 0700 root root -"
    "d /var/lib/fingerprintd/sfs 0700 root root -"
    "d /var/lib/fingerprintd/sfs/tzstorage 0700 root root -"
    "d /var/lib/fingerprintd/sfs/misc 0700 root root -"
    "L /var/lib/fingerprintd/sfs/persist-data - - - - /mnt/persist/data"
    "L /var/lib/fingerprintd/sfs/root3 - - - - /mnt/persist/data"
  ];
  systemd.services.fp6-fingerprint-firmware = {
    description = "Extract the FP6 signed fingerprint firmware";
    unitConfig.ConditionPathExists = "!/var/lib/fingerprintd/focal64.mbn";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${firmware}/bin/fp6-fingerprint-firmware";
      StateDirectory = "fingerprintd";
      StateDirectoryMode = "0700";
    };
  };
  # D-Bus activation starts this on demand, outside the graphical boot path.
  systemd.services.fingerprintd = {
    description = "FP6 FocalTech fingerprint sensor";
    requires = [ "fp6-fingerprint-firmware.service" ];
    after = [
      "dbus.service"
      "fp6-fingerprint-firmware.service"
      "systemd-tmpfiles-setup.service"
    ];
    unitConfig = {
      ConditionPathExists = "/dev/tee0";
      RequiresMountsFor = "/mnt/persist";
    };
    serviceConfig = {
      Type = "dbus";
      BusName = "net.reactivated.Fprint";
      # Morf's lock screen keeps a verify open for as long as it is up, even
      # with the display off. Each frame is ~170 ms of QTEE work, so the
      # default 40 ms gap held a core at ~75%; 400 ms brings it to ~30%.
      # Edge wake still catches a landing finger during the gap.
      ExecStart = "${fingerprintd}/bin/fingerprintd --daemon --edge-wake --frame-gap=400 --standby-unlock=off --learn=0 --sfs-writable --rpmb-write";
      StateDirectory = "fingerprintd";
      StateDirectoryMode = "0700";
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = 5;
      KillMode = "mixed";
      TimeoutStopSec = 15;
    };
  };

  # Morf listens on this separate PAM stack alongside its password prompt.
  # A rejected finger must not fall through to a password attempt or affect
  # password failure counters. Other authentication services keep their policy.
  security.pam.services.morf-lock-finger = lib.mkIf config.programs.eva.enable {
    text = ''
      auth sufficient ${clients}/lib/security/pam_fprintd.so
      auth required ${config.security.pam.package}/lib/security/pam_deny.so
      account include morf-lock
    '';
  };
}
