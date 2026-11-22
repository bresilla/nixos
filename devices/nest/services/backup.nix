{ lib, ... }:

let
  # Every share btrbk snapshots (@cache-chunks is left out on purpose); the same list
  # every dump target copies.
  inherit (import ../../../services/dump/source.nix) source;
in
{
  # The top of the data pool, where btrbk sees every share and keeps its snapshots.
  fileSystems."/mnt/data-store" = {
    device = "/dev/data/store";
    fsType = "btrfs";
    options = [ "subvol=/" "noatime" "compress=zstd:3" "nofail" "x-systemd.requires=data-subvolumes.service" "x-systemd.after=data-subvolumes.service" ];
  };

  # Hourly snapshots, kept 48 h then daily for 7 days. The dump targets (services/dump)
  # pull these each night; 48 h keeps the one a target fetched the night before, so the
  # next fetch can send only what changed.
  services.btrbk.instances.hourly = {
    onCalendar = "*-*-* *:30:00";
    snapshotOnly = true;
    settings = {
      timestamp_format = "long";
      snapshot_preserve_min = "2h";
      snapshot_preserve = "48h 7d";
      volume.${source.volume} = { snapshot_dir = source.snapshotDir; subvolume = lib.genAttrs source.shares (_: { }); };
    };
  };

  # A bad sector on the data pool shows up here rather than on the day of a restore.
  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/mnt/data-store" ];
    interval = "monthly";
  };
}
