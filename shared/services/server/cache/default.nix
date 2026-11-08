# Attic with its web page, nightly backup and pin-aware cleanup, as one service for a
# NixOS container. The host adds the container, its storage at /srv/attic and its proxy.
{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.cache;
  # Databases and pins on the container own disk; chunks on /srv/attic.
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
  # The same confinement atticd ships with, for the units around it.
  sandbox = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectProc = "invisible";
    ProtectClock = true;
    ProtectHostname = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" ];
    UMask = "0077";
  };
  uiEnv = {
    CACHE_DB = "${dir}/server.db";
    CACHE_UI_DB = "${dir}/ui.db";
    CACHE_URL = cfg.url;
    CACHE_LOGO = "${../../../../configs/assets/bresilla.svg}";
    CACHE_PINS_FILE = "${dir}/pins.json";
    CACHE_LISTEN = "127.0.0.1:8082";
    CACHE_API = "http://127.0.0.1:8081";
    CACHE_ATTICADM = atticadm;
    CACHE_GC = gcOnce;
  };
in {
  options.bresilla.services.cache = {
    url = lib.mkOption {
      type = lib.types.str;
      description = "The public URL of the cache.";
    };
    proxy = lib.mkOption {
      type = lib.types.str;
      description = "Address of the proxy in front of it, trusted for the client scheme.";
    };
    uid = lib.mkOption {
      type = lib.types.int;
      description = "Fixed atticd user, so files on shared storage keep their owner.";
    };
    login = lib.mkOption {
      default = null;
      description = "Sign-in to the page through an OpenID Connect provider, by a login proxy.";
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          issuer = lib.mkOption { type = lib.types.str; };
          client = lib.mkOption { type = lib.types.str; };
          envFile = lib.mkOption { type = lib.types.str; description = "OAUTH2_PROXY_CLIENT_SECRET and _COOKIE_SECRET."; };
          adminClaim = lib.mkOption { type = lib.types.str; description = "Claim whose value \"admin\" lets a user change things."; };
        };
      });
    };
  };

  config = {
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

    # A fixed user, so chunk files keep their owner across rebuilds.
    users.users.atticd = { isSystemUser = true; inherit (cfg) uid; group = "atticd"; home = dir; };
    users.groups.atticd.gid = cfg.uid;
    systemd.services.atticd = {
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        ReadWritePaths = [ dir storage ];
        # The local directory as root; on shared storage only atticd may write.
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/install -d -o atticd -g atticd -m 0750 ${dir}"
          "${pkgs.coreutils}/bin/mkdir -p ${storage}"
        ];
      };
      unitConfig.RequiresMountsFor = [ storage ];
    };

    # Nightly database, pins and secrets copy next to the chunks; 14 days kept.
    systemd.services.attic-backup = {
      # As atticd, the only user that may write there; it owns the secrets too.
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "atticd";
        Group = "atticd";
        ReadWritePaths = [ dir "/srv/attic/backups" ];
      };
      path = [ pkgs.sqlite pkgs.findutils pkgs.coreutils ];
      script = ''
        out=/srv/attic/backups/$(date +%F)
        install -d -m 0700 "$out"
        sqlite3 ${dir}/server.db ".backup '$out/server.db'"
        sqlite3 ${dir}/ui.db ".backup '$out/ui.db'"
        cp -f ${dir}/pins.json /var/lib/atticd.env "$out/"
        cp -f /var/lib/cache-ui.env "$out/" 2>/dev/null || true
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
      path = [ pkgs.sqlite pkgs.jq ];
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "atticd";
        Group = "atticd";
        EnvironmentFile = "/var/lib/atticd.env";
        ReadWritePaths = [ dir storage ];
      };
      script = ''
        # Every pin lives in the cache UI's own pins file; never prune on an empty one.
        if jq -e 'type == "object" and length > 0' ${dir}/pins.json > /dev/null 2>&1; then
          # attic may hold the database a moment while it restarts with a switch
          sqlite3 -cmd ".timeout 30000" ${dir}/server.db <<SQL
        -- every pin, for each pruned cache; a pin only keeps what its own cache holds
        CREATE TEMP TABLE pinned AS
          SELECT c.value AS cache, p.value ->> 'storePath' AS path
          FROM json_each('["bresilla","packages"]') c, json_each(readfile('${dir}/pins.json')) p;
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
          -- /kernels and /firmwares hold unpinned paths on purpose and are never pruned here.
          WHERE c.name IN ('bresilla', 'packages')
            -- never on a pins file that matches nothing in this cache
            AND EXISTS (SELECT 1 FROM kept WHERE cache_id = o.cache_id)
            AND NOT EXISTS (SELECT 1 FROM kept WHERE cache_id = o.cache_id AND path = o.store_path)
            -- CI pushes before it pins; spare anything that fresh
            AND julianday(replace(substr(o.created_at, 1, 19), 'T', ' ')) < julianday('now', '-1 day');
        SELECT 'unpinned, deleting: ' || substr(store_path, 12) FROM doomed;
        DELETE FROM object WHERE id IN (SELECT id FROM doomed);
        SQL
        else
          echo "no pins; skipping the unpinned cleanup"
        fi

        for pass in $(seq 1 200); do
          ${gcOnce}
          left=$(sqlite3 -cmd ".timeout 30000" ${dir}/server.db "SELECT COUNT(*) FROM chunk WHERE state = 'D'")
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
      serviceConfig = sandbox // {
        ExecStart = "${pkgs.python3}/bin/python3 ${./ui.py}";
        # The pin token, and Attic's signing key for minting tokens.
        EnvironmentFile = [ "-/var/lib/cache-ui.env" "/var/lib/atticd.env" ];
        User = "atticd";
        Group = "atticd";
        Restart = "on-failure";
        ReadWritePaths = [ dir storage ];
      };
    };

    # Port 8080 needs no capabilities; the packaged unit grants two.
    systemd.services.caddy.serviceConfig = sandbox // { ProtectSystem = lib.mkForce "strict"; };

    # One port for both: the page at / and /-/, everything else is Attic itself.
    services.caddy = {
      enable = true;
      # The proxy says the client used https; Attic builds its endpoint from that.
      globalConfig = ''
        servers {
          trusted_proxies static ${cfg.proxy}/32
        }
      '';
      # The page is open to everyone. Each request first asks the login proxy whether
      # someone is signed in; if so, their name and role go along, and nobody can
      # send those headers themselves. Pins stay open to machines and CI (their own
      # token guards changes), with no one's name on them.
      virtualHosts."http://:8080".extraConfig = let
        strip = ''
          request_header -X-Forwarded-User
          request_header -X-Forwarded-Preferred-Username
          request_header -X-Forwarded-Groups
          request_header -X-Forwarded-Email
        '';
        # Signed out, the empty handle_response lets the request go on without a name.
        who = lib.optionalString (cfg.login != null) ''
          forward_auth 127.0.0.1:4180 {
            uri /oauth2/auth
            copy_headers X-Auth-Request-Preferred-Username>X-Forwarded-Preferred-Username X-Auth-Request-Groups>X-Forwarded-Groups
            handle_response {
            }
          }
        '';
      in ''
        # Only over HTTPS from now on, never inside another site's frame.
        header {
          Strict-Transport-Security "max-age=63072000"
          X-Frame-Options DENY
          X-Content-Type-Options nosniff
          Referrer-Policy same-origin
        }
        handle /-/pins* {
          route {
            ${strip}
            reverse_proxy 127.0.0.1:8082
          }
        }
        handle /oauth2/* {
          reverse_proxy 127.0.0.1:4180
        }
        @page {
          path / /-/*
          not path /-/pins*
        }
        handle @page {
          route {
            ${strip}
            ${who}
            reverse_proxy 127.0.0.1:8082
          }
        }
        handle {
          reverse_proxy 127.0.0.1:8081
        }
      '';
    };

    # It looks the provider up at start, so names must resolve; it keeps trying.
    systemd.services.oauth2-proxy = lib.mkIf (cfg.login != null) {
      after = [ "network-online.target" "resolvconf.service" ];
      wants = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      serviceConfig.RestartSec = 10;
    };

    services.oauth2-proxy = lib.mkIf (cfg.login != null) {
      enable = true;
      provider = "oidc";
      clientID = cfg.login.client;
      keyFile = cfg.login.envFile;
      oidcIssuerUrl = cfg.login.issuer;
      redirectURL = "${cfg.url}/oauth2/callback";
      httpAddress = "http://127.0.0.1:4180";
      upstream = [ "http://127.0.0.1:8082" ];
      email.domains = [ "*" ];
      reverseProxy = true;
      trustedProxyIP = [ "127.0.0.1" ];
      scope = "openid email profile";
      cookie = { name = "_cache_login"; secure = true; expire = "336h0m0s"; };
      approvalPrompt = "auto";
      passBasicAuth = false;
      extraConfig = {
        # Straight to id.bresilla.com, no page of its own in between.
        skip-provider-button = true;
        # Signing out ends the session on the provider too, on its own domain.
        whitelist-domain = builtins.elemAt (lib.splitString "/" cfg.login.issuer) 2;
        code-challenge-method = "S256";
        oidc-groups-claim = cfg.login.adminClaim;
        # Answers "who is this?" for the page, which is open to everyone.
        set-xauthrequest = true;
        insecure-oidc-allow-unverified-email = true;
      };
    };

    system.stateVersion = "26.05";
    # Only the host reaches this network.
    networking.firewall.enable = false;
    # The host's resolver listens on its own loopback, which this network can't reach.
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
  };
}
