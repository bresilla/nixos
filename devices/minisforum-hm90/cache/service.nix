# Runs inside hive's cache container; `proxy` is the host side, where cloudflared connects from.
{ proxy, uid }:
{ config, lib, pkgs, ... }:

let
  # Databases and pins on the container's own disk; chunks on nest over NFS.
  dir = "/var/lib/atticd";
  storage = "/srv/attic/storage";
  # The service's own command line, switched to a single garbage-collection pass.
  gcOnce = let
    cmd = builtins.replaceStrings [ "--mode ${config.services.atticd.mode}" ]
      [ "--mode garbage-collector-once" ] config.systemd.services.atticd.serviceConfig.ExecStart;
  in assert lib.assertMsg (lib.hasInfix "garbage-collector-once" cmd)
    "attic-gc: could not derive a garbage-collection command from atticd's ExecStart"; cmd;
  # The same config file for atticadm, which mints tokens.
  atticadm = let
    cmd = builtins.replaceStrings [ "/bin/atticd " "--mode ${config.services.atticd.mode}" ]
      [ "/bin/atticadm " "" ] config.systemd.services.atticd.serviceConfig.ExecStart;
  in assert lib.assertMsg (lib.hasInfix "/bin/atticadm -f " cmd)
    "cache-ui: could not derive an atticadm command from atticd's ExecStart"; cmd;
  uiEnv = {
    CACHE_DB = "${dir}/server.db";
    CACHE_UI_DB = "${dir}/ui.db";
    CACHE_URL = "https://cache.bresilla.com";
    CACHE_LOGO = "${../../../configs/assets/bresilla.svg}";
    CACHE_PINS = "${../../../packages/pins.json}";
    CACHE_PINS_FILE = "${dir}/pins.json";
    CACHE_LISTEN = "127.0.0.1:8082";
    CACHE_API = "http://127.0.0.1:8081";
    CACHE_ATTICADM = atticadm;
    CACHE_GC = gcOnce;
  };
in {
  # Accounts for the cache page: `sudo cache-ui-user add <name>`, `remove <name>`, `list`.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "cache-ui-user" ''
      exec ${pkgs.util-linux}/bin/runuser -u atticd -- \
        ${pkgs.coreutils}/bin/env CACHE_UI_DB=${uiEnv.CACHE_UI_DB} ${pkgs.python3}/bin/python3 ${./ui.py} user "$@"
    '')
  ];

  # Attic binary cache; the signing secret lives only in the container's
  # /var/lib/atticd.env, never in git.
  services.atticd = {
    enable = true;
    environmentFile = "/var/lib/atticd.env";
    settings = {
      listen = "127.0.0.1:8081";
      # No api-endpoint: clients would switch every upload to it, so pushes over
      # NetBird would still go through Cloudflare and its 100 MB cap.
      database.url = "sqlite://${dir}/server.db?mode=rwc";
      storage = { type = "local"; path = storage; };
    };
  };

  # A fixed user, so chunk files on nest keep their owner across rebuilds.
  users.users.atticd = { isSystemUser = true; inherit uid; group = "atticd"; home = dir; };
  users.groups.atticd.gid = uid;
  systemd.services.atticd = {
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      ReadWritePaths = [ dir storage ];
      # The local directory as root; on nest's share only atticd may write.
      ExecStartPre = [
        "+${pkgs.coreutils}/bin/install -d -o atticd -g atticd -m 0750 ${dir}"
        "${pkgs.coreutils}/bin/mkdir -p ${storage}"
      ];
    };
    unitConfig.RequiresMountsFor = [ storage ];
  };

  # One-time takeover from nest: databases, pins and secrets it left on the share
  # move into this container, the old copies into backups/pre-hive. Remove once done.
  systemd.services.attic-takeover = {
    wantedBy = [ "multi-user.target" ];
    before = [ "atticd.service" "cache-ui.service" ];
    requiredBy = [ "atticd.service" "cache-ui.service" ];
    unitConfig = {
      RequiresMountsFor = [ storage ];
      ConditionPathExists = [ "/srv/attic/migrate/atticd.env" "!${dir}/server.db" ];
    };
    path = [ pkgs.coreutils pkgs.util-linux pkgs.bash ];
    serviceConfig.Type = "oneshot";
    script = ''
      cd /srv/attic
      install -d -o atticd -g atticd -m 0750 ${dir}
      for f in server.db server.db-wal ui.db pins.json; do
        if [ -e "$f" ]; then runuser -u atticd -- cp -p "$f" ${dir}/; fi
      done
      for f in atticd.env cache-ui.env; do
        runuser -u atticd -- cat "migrate/$f" > "/var/lib/$f"
        chown atticd:atticd "/var/lib/$f"; chmod 0400 "/var/lib/$f"
      done
      runuser -u atticd -- mkdir -p backups/pre-hive
      runuser -u atticd -- bash -c 'mv server.db* ui.db pins.json backups/pre-hive/ && rm -rf migrate'
    '';
  };

  # Nightly database, pins and secrets copy onto nest, next to the chunks; 14 days kept.
  systemd.services.attic-backup = {
    # As atticd, the only user that may write on nest's share; it owns the secrets too.
    serviceConfig = { Type = "oneshot"; User = "atticd"; Group = "atticd"; };
    path = [ pkgs.sqlite pkgs.findutils pkgs.coreutils ];
    script = ''
      out=/srv/attic/backups/$(date +%F)
      install -d -m 0700 "$out"
      sqlite3 ${dir}/server.db ".backup '$out/server.db'"
      sqlite3 ${dir}/ui.db ".backup '$out/ui.db'"
      cp ${dir}/pins.json /var/lib/atticd.env "$out/"
      cp /var/lib/cache-ui.env "$out/" 2>/dev/null || true
      find /srv/attic/backups -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
    '';
  };
  systemd.timers.attic-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "03:30"; Persistent = true; };
  };

  # Nightly, and once on every switch: drop builds that are no longer pinned, then
  # free their data. Attic frees at most 500 chunk files per pass, so passes repeat
  # until none is left.
  systemd.services.attic-gc = {
    after = [ "atticd.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    startAt = "daily";
    unitConfig.RequiresMountsFor = [ storage ];
    environment.RUST_LOG = "info";
    path = [ pkgs.sqlite pkgs.curl pkgs.jq ];
    serviceConfig = {
      Type = "oneshot";
      User = "atticd";
      Group = "atticd";
      EnvironmentFile = "/var/lib/atticd.env";
      ReadWritePaths = [ dir storage ];
    };
    script = ''
      # The pins on main, not the copy built into this system: that one is stale
      # whenever CI has pushed since hive last updated.
      pins=$(mktemp)
      trap 'rm -f "$pins"' EXIT
      if curl -fsS --max-time 30 -o "$pins" \
          https://raw.githubusercontent.com/bresilla/nixos/main/packages/pins.json \
        && jq -e 'type == "object" and ([.[][]] | length) > 0' "$pins" > /dev/null; then
        sqlite3 ${dir}/server.db <<SQL
      -- packages/pins.json holds /packages; the pins API (termworks, paneworks, ai-nerv) /bresilla
      CREATE TEMP TABLE pinned AS
        SELECT 'packages' AS cache, p.value AS path FROM json_each(readfile('$pins')) s, json_each(s.value) p;
      INSERT INTO pinned SELECT 'bresilla', value ->> 'storePath' FROM json_each(readfile('${dir}/pins.json'));
      -- pinned builds and their whole closure within the same cache
      CREATE TEMP TABLE kept AS
        WITH RECURSIVE k(cache_id, path) AS (
          SELECT o.cache_id, o.store_path FROM object o JOIN cache c ON c.id = o.cache_id
            JOIN pinned q ON q.path = o.store_path AND q.cache = c.name
          UNION
          SELECT k.cache_id, d.store_path FROM k
            JOIN object p ON p.cache_id = k.cache_id AND p.store_path = k.path
            JOIN object d ON d.cache_id = k.cache_id
              AND p."references" LIKE '%' || substr(d.store_path, 12) || '%')
        SELECT * FROM k;
      CREATE TEMP TABLE doomed AS
        SELECT o.id, o.store_path FROM object o JOIN cache c ON c.id = o.cache_id
        -- /kernels holds unpinned kernels on purpose and is never pruned here.
        WHERE c.name IN ('bresilla', 'packages')
          -- never on a pins file that matches nothing in this cache
          AND EXISTS (SELECT 1 FROM kept WHERE cache_id = o.cache_id)
          AND NOT EXISTS (SELECT 1 FROM kept WHERE cache_id = o.cache_id AND path = o.store_path)
          -- CI pushes before it commits the pins; spare anything that fresh
          AND julianday(replace(substr(o.created_at, 1, 19), 'T', ' ')) < julianday('now', '-1 day');
      SELECT 'unpinned, deleting: ' || substr(store_path, 12) FROM doomed;
      DELETE FROM object WHERE id IN (SELECT id FROM doomed);
      SQL
      else
        echo "pins on main unavailable; skipping the unpinned cleanup"
      fi

      for pass in $(seq 1 200); do
        ${gcOnce}
        left=$(sqlite3 ${dir}/server.db "SELECT COUNT(*) FROM chunk WHERE state = 'D'")
        echo "pass $pass: $left deleted chunks left"
        [ "$left" -eq 0 ] && break
      done
    '';
  };

  # The web page (public caches for everyone, management for accounts) and the pins API;
  # the pin token lives only in the container's /var/lib/cache-ui.env; without it every PUT is refused.
  systemd.services.cache-ui = {
    wantedBy = [ "multi-user.target" ];
    after = [ "atticd.service" ];
    unitConfig.RequiresMountsFor = [ storage ];
    environment = uiEnv;
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./ui.py}";
      # The pin token, and Attic's signing key for minting tokens.
      EnvironmentFile = [ "-/var/lib/cache-ui.env" "/var/lib/atticd.env" ];
      User = "atticd";
      Group = "atticd";
      Restart = "on-failure";
      ProtectSystem = "strict";
      ReadWritePaths = [ dir storage ];
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  # One port for both: the page at / and /-/, everything else is Attic itself.
  services.caddy = {
    enable = true;
    # hive's cloudflared says the client used https; Attic builds its endpoint from that.
    globalConfig = ''
      servers {
        trusted_proxies static ${proxy}/32
      }
    '';
    virtualHosts."http://:8080".extraConfig = ''
      handle / {
        reverse_proxy 127.0.0.1:8082
      }
      handle /-/* {
        reverse_proxy 127.0.0.1:8082
      }
      handle {
        reverse_proxy 127.0.0.1:8081
      }
    '';
  };

  system.stateVersion = "26.05";
  # Only hive reaches this network: its tunnel, and NetBird pushes forwarded to :8080.
  networking.firewall.enable = false;
  # The host's resolver listens on its own loopback, which this network can't reach.
  networking.useHostResolvConf = false;
  networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
}
