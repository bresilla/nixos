{ config, pkgs, ... }:
{
  networking.modemmanager.fccUnlockScripts = [{
    id = "8086:7360";
    path = "${config.networking.modemmanager.package}/share/ModemManager/fcc-unlock.available.d/8086:7360";
  }];
  # The upstream XMM7360 helper uses xxd in addition to the standard tools.
  systemd.services.ModemManager.path = [ pkgs.xxd ];
}
