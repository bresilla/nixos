{
  config,
  lib,
  pkgs,
  ...
}:
{
  networking.modemmanager.fccUnlockScripts = [
    {
      id = "8086:7360";
      path = "${config.networking.modemmanager.package}/share/ModemManager/fcc-unlock.available.d/8086:7360";
    }
  ];
  # The upstream XMM7360 helper uses xxd in addition to the standard tools.
  systemd.services.ModemManager.path = [ pkgs.xxd ];

  # The XMM7360 enters a firmware crash state (A-CD_READY) after S3 with
  # iosm attached. Reinitialize it as the driver already does for S4.
  systemd.services.t480-modem-sleep = lib.mkIf config.networking.modemmanager.enable {
    description = "Reinitialize the T480 modem around sleep";
    wantedBy = [ "sleep.target" ];
    before = [ "sleep.target" ];
    unitConfig = {
      StopWhenUnneeded = true;
      ConditionPathExists = "/sys/module/iosm";
    };
    path = [
      pkgs.kmod
      pkgs.systemd
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 30;
      TimeoutStopSec = 30;
    };
    script = ''
      systemctl stop ModemManager.service
      modprobe -r iosm
    '';
    # Also restore ModemManager if preparation fails or sleep is cancelled.
    postStop = ''
      modprobe iosm
      systemctl start ModemManager.service
    '';
  };
}
