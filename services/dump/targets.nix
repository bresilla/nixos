# Where nest's shares are copied every night ("dump"). A btrbk target is a btrfs disk in
# some machine that pulls nest's newest snapshots over NetBird; a restic target is an
# encrypted repository anywhere restic or rclone reaches (Google Drive, OneDrive, B2...).
# Add an entry here, then update nest and the machine it names.
{
  # What every target copies: nest's own snapshots, kept there hourly by btrbk.
  source = {
    host = "nest";
    address = "nest.netbird";
    hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIItkQq+2vyMwn6PjeyUjXjCPYLIWSVxQvbb8X1LpQx0+";
    volume = "/mnt/data-store";
    snapshotDir = ".snapshots";
    shares = [ "@git" "@cache" "@build" "@id" "@vault" "@net" "@s3" ];
  };

  targets = {
    tron = {
      kind = "btrbk";
      host = "tron";
      # Wiped once by hand into LVM (volume group dump, volume tron) with btrfs inside.
      disk = "/dev/disk/by-id/ata-TS4TSSD230S_I216000111";
      keep = "14d 8w 12m";
      # tron's pull key (dump-key.service makes it); nest lets it only read snapshots.
      key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAHyZBdKJXjdP+ZHJNY/rl9eAHCKR3qVe30SGK6+O4Qj dump@tron";
    };

    # gdrive = {
    #   kind = "restic";
    #   repository = "rclone:gdrive:dump";
    #   keep = "7d 4w 12m";
    # };
  };
}
