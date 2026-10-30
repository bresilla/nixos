{ pkgs, ... }:
{
  # One-time handover of the cache to hive's container: its secrets go beside the
  # data, and the container's atticd (3001 + 524288) gets the share. Remove once done.
  systemd.services.attic-handover = {
    wantedBy = [ "multi-user.target" ];
    after = [ "data-subvolumes.service" ];
    unitConfig = {
      RequiresMountsFor = [ "/data/attic" ];
      ConditionPathExists = "/var/lib/atticd.env";
    };
    path = [ pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      install -d -m 0700 /data/attic/migrate
      cp /var/lib/atticd.env /var/lib/cache-ui.env /data/attic/migrate/
      chown -R 527289:527289 /data/attic
      install -d -m 0700 /root/attic-moved
      mv /var/lib/atticd.env /var/lib/cache-ui.env /root/attic-moved/
    '';
  };
}
