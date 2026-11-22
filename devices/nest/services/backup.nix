{ config, lib, ... }:

let
  source = config.bresilla.dump.manager;
in
{
  # The top of the data pool, where btrbk sees every share and keeps its snapshots.
  fileSystems."/mnt/data-store" = {
    device = "/dev/data/store";
    fsType = "btrfs";
    options = [ "subvol=/" "noatime" "compress=zstd:3" "nofail" "x-systemd.requires=data-subvolumes.service" "x-systemd.after=data-subvolumes.service" ];
  };

  # Hourly snapshots, named in UTC, kept 48 h then daily (the 05:30 UTC one) for 7 days.
  # dump pushes these each night; 48 h keeps the one sent the night before, so the
  # next push sends only what changed.
  services.btrbk.instances.hourly = {
    onCalendar = "*-*-* *:30:00";
    snapshotOnly = true;
    settings = {
      timestamp_format = "long";
      preserve_hour_of_day = "5";
      snapshot_preserve_min = "2h";
      snapshot_preserve = "48h 7d";
      volume.${source.volume} = { snapshot_dir = source.snapshotDir; subvolume = lib.genAttrs source.shares (_: { }); };
    };
  };
  systemd.services.btrbk-hourly.environment.TZ = "UTC";

  # A bad sector on the data pool shows up here rather than on the day of a restore.
  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/" "/mnt/data-store" ];
    interval = "monthly";
  };
}
