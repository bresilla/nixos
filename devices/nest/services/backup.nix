{ lib, ... }:

let
  # Today's shares; @gitea and @attic become @git and @cache in MIGRATE.md phase 3.
  shares = [ "@gitea" "@attic" "@build" "@id" "@vault" "@net" "@s3" ];
  # Both runs share the snapshots, so both keep them the same way.
  common = {
    timestamp_format = "long";
    snapshot_preserve_min = "2h";
    snapshot_preserve = "24h 7d";
  };
  store = extra: {
    "/mnt/data-store" = { snapshot_dir = ".snapshots"; subvolume = lib.genAttrs shares (_: { }); } // extra;
  };
in
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

  # The top of the data pool, where btrbk sees every share and keeps its snapshots.
  fileSystems."/mnt/data-store" = {
    device = "/dev/data/store";
    fsType = "btrfs";
    options = [ "subvol=/" "noatime" "compress=zstd:3" "nofail" "x-systemd.requires=data-subvolumes.service" "x-systemd.after=data-subvolumes.service" ];
  };

  # Hourly snapshots on nest; each night after the services' own copies (04:30 UTC),
  # one more and its incremental send to the drive.
  services.btrbk.instances = {
    hourly = {
      onCalendar = "*-*-* *:30:00";
      snapshotOnly = true;
      settings = common // { volume = store { }; };
    };
    nightly = {
      onCalendar = "*-*-* 05:00:00 UTC";
      settings = common // {
        target_preserve_min = "no";
        target_preserve = "14d 8w 12m";
        volume = store { target = "/mnt/backup"; };
      };
    };
  };

  # A bad sector on the drive shows up here rather than on the day of a restore.
  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/mnt/backup" ];
    interval = "monthly";
  };
}
