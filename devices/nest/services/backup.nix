{
  # The USB backup drive: LUKS over the whole disk, btrfs inside, for btrbk's copies.
  # The key file stays on nest's own disk (a copy in gopass); nest boots without the drive.
  environment.etc.crypttab.text = ''
    backup UUID=ad19a2bd-cc58-4803-aa06-cdba5cb0a630 /var/lib/backup-drive/key luks,nofail,x-systemd.device-timeout=10s
  '';

  # Its Ugreen enclosure (JMicron JMS583) is known to drop writes over UAS; plain
  # usb-storage, which also reports the drive's serial.
  boot.kernelParams = [ "usb-storage.quirks=152d:0583:u" ];

  fileSystems."/mnt/backup" = {
    device = "/dev/mapper/backup";
    fsType = "btrfs";
    options = [ "noatime" "compress=zstd:3" "nofail" "x-systemd.device-timeout=10s" ];
  };
}
