# nest's shares, each a btrfs subvolume @<name> at /data/<name>, exported to hive.
# uid: its owner inside hive's container (hive shifts container uids by idBase, and NFS
# keeps numeric owners); none is root's. split: the config/ (root's, encrypted copies)
# and data/ layout. backup: snapshotted hourly and pushed by dump.
{
  idBase = 524288;
  shares = {
    git = { uid = 3000; split = true; backup = true; };
    cache = { uid = 3001; split = true; backup = true; };
    cache-chunks = { uid = 3001; split = false; backup = false; };
    id = { split = true; backup = true; };
    s3 = { uid = 3002; split = true; backup = true; };
    build = { split = true; backup = true; };
    vault = { split = true; backup = true; };
    net = { split = true; backup = true; };
  };
}
