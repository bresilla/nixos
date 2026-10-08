{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Name the IPA data link when ModemManager creates it, so its bearer and
  # NetworkManager both track qrtr0. A later udev rename would race them.
  # Patch only the service package; desktop applications keep the cached SDK.
  options.networking.modemmanager.package = lib.mkOption {
    apply =
      package:
      package.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./patches/qrtr-interface.patch ];
      });
  };

  config = lib.mkIf config.networking.modemmanager.enable {
    environment.systemPackages = [
      pkgs.libqmi
      pkgs.qrtr
    ];
    systemd.services.fp6-tqftp = {
      description = "FP6 modem carrier firmware transfer";
      wantedBy = [ "multi-user.target" ];
      before = [ "fp6-rmtfs.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.tqftpserv}/bin/tqftpserv";
        Restart = "on-failure";
        RestartSec = 5;
        PrivateTmp = true;
      };
    };
    # The kernel provides QRTR and PD mapping. rmtfs serves the existing
    # calibration partitions and starts the modem through remoteproc.
    systemd.services.fp6-rmtfs = {
      description = "FP6 modem firmware storage";
      wantedBy = [ "multi-user.target" ];
      requires = [ "fp6-tqftp.service" ];
      after = [
        "systemd-udev-trigger.service"
        "fp6-tqftp.service"
      ];
      before = [ "ModemManager.service" ];
      serviceConfig = {
        # Match upstream's read-only backing storage: modem writes stay in RAM.
        ExecStart = "${pkgs.rmtfs}/bin/rmtfs -r -P -s";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
    systemd.services.ModemManager = {
      wants = [ "fp6-rmtfs.service" ];
      after = [ "fp6-rmtfs.service" ];
      # Wait for QMI and initialize the SIM before ModemManager probes it.
      # This does not enter a PIN or select a carrier/APN.
      preStart = ''
        ${pkgs.python3}/bin/python3 ${./scripts/modem-sim.py} ${pkgs.libqmi}/bin/qmicli
      '';
    };
  };
}
