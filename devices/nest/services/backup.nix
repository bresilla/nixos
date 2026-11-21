{
  # The USB backup drive: LUKS over the whole disk, btrfs inside, for btrbk's copies.
  # The key file stays on nest's own disk (a copy in gopass); nest boots without the drive.
  environment.etc.crypttab.text = ''
    backup /dev/disk/by-id/usb-WDS100T1_X0E-00AFY0_152D05830D0D-0:0 /var/lib/backup-drive/key luks,nofail,x-systemd.device-timeout=10s
  '';

  fileSystems."/mnt/backup" = {
    device = "/dev/mapper/backup";
    fsType = "btrfs";
    options = [ "noatime" "compress=zstd:3" "nofail" "x-systemd.device-timeout=10s" ];
  };
}
