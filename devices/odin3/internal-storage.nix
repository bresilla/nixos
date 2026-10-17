{ lib, ... }:
{
  # Android and its firmware partitions live on the internal UFS; NixOS runs
  # from USB and must never mount or offer them, nor update UFS firmware.
  services.udev.extraRules = ''
    SUBSYSTEM=="block", ENV{ID_PATH}=="platform-1d84000.ufs-*", ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0"
  '';
  services.fwupd.enable = lib.mkForce false;
}
