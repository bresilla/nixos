# nest pushes its btrbk snapshots to the dump targets listed on hive's hub.
# dump.json beside this holds nest's manager key, which each target accepts.
{
  bresilla.dump.manager = {
    enable = true;
    hub = "http://10.99.0.1:9103";
    volume = "/mnt/data-store";
    snapshotDir = ".snapshots";
    # Every share btrbk snapshots; @cache-chunks is left out on purpose.
    shares = [ "@git" "@cache" "@build" "@id" "@vault" "@net" "@s3" ];
  };
}
