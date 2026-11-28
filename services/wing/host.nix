# wing.bresilla.com on hive: projects, tasks and plans, out through the Cloudflare tunnel.
# Pages only after signing in at id.bresilla.com; /api for the wing CLI with its own token.
{ config, lib, pkgs, termworks, ... }:
let
  cfg = config.bresilla.server.wing;
  mnt = config.bresilla.server.storage.mount;
  domain = "wing.bresilla.com";
  hostAddress = "10.231.11.1";
  address = "10.231.11.2";
in {
  options.bresilla.server.wing.enable = lib.mkEnableOption "projects and tasks, wing.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "wing" ];
    bresilla.server.tunnel.ingress.${domain} = "http://${address}:8080";
    # Outbound only (git and build for project facts); nothing outside hive opens a connection to it.
    networking.nat = { enable = true; internalInterfaces = [ "ve-wing" ]; };
    bresilla.server.containerNet.wing = { host = hostAddress; local = address; };

    # The database, copied every hour to wing's share on nest (snapshotted there hourly),
    # one folder a day for 14 days; SQLite's own backup is safe while it is in use. Each copy
    # is opened again and read before it counts: a copy that cannot be restored fails the unit.
    bresilla.server.shares."wing" = "wing";
    systemd.services.wing-backup = {
      description = "Copy ${domain}'s database to nest";
      unitConfig.RequiresMountsFor = [ "${mnt}/wing" ];
      serviceConfig = { Type = "oneshot"; Nice = 10; };
      path = [ pkgs.sqlite pkgs.coreutils pkgs.findutils ];
      script = ''
        db=/var/lib/nixos-containers/wing/var/lib/wing/wing.db
        [ -f "$db" ] || exit 0
        dst=${mnt}/wing/data/$(date -u +%F)
        install -d -m 0700 "$dst"
        sqlite3 "$db" ".backup '$dst/wing.db.new'"
        if [ "$(sqlite3 "$dst/wing.db.new" 'PRAGMA integrity_check')" != ok ] ||
           ! sqlite3 "$dst/wing.db.new" 'SELECT count(*) FROM projects; SELECT count(*) FROM tasks; SELECT count(*) FROM bundles' > /dev/null; then
          echo "the copy of $db does not read back; the last good one is kept" >&2
          rm -f "$dst/wing.db.new"
          exit 1
        fi
        mv "$dst/wing.db.new" "$dst/wing.db"
        find ${mnt}/wing/data -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
      '';
    };
    systemd.timers.wing-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "hourly"; Persistent = true; };
    };

    containers.wing = {
      autoStart = true;
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      config = {
        imports = [ ./. ];
        bresilla.services.wing = {
          inherit domain;
          # What a new site starts with: the templates wing ships, and the skills repository.
          seed = { templates = "${termworks.wing.packages.${pkgs.stdenv.hostPlatform.system}.wing}/share/wing/templates"; skills = "https://git.bresilla.com/bresilla/skills.git"; };
          login = {
            issuer = "https://id.bresilla.com/oauth2/openid/wing";
            client = "wing";
            envFile = "/var/lib/oidc/proxy.env";
          };
        };
      };
    };
  };
}
