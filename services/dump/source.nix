# What dump copies, and how its parts find each other. The targets themselves are not
# here: they are added and removed on status.bresilla.com and kept on hive
# (/var/lib/dump/targets.json).
{
  # nest's own snapshots, kept there hourly by btrbk; every target gets these.
  source = {
    host = "nest";
    volume = "/mnt/data-store";
    snapshotDir = ".snapshots";
    shares = [ "@git" "@cache" "@build" "@id" "@vault" "@net" "@s3" ];
  };

  # hive's hub, which nest's manager reaches over their cable.
  hub = { link = "10.99.0.1"; nest = "10.99.0.2"; port = 9103; };

  # nest's manager key (made on nest at its first run); a target's `dump` user accepts it.
  managerKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIowHHcNX/+IiW7vYvy0Si19MzbZV1Y+Dga8I+cUKC8D dump@nest";
}
