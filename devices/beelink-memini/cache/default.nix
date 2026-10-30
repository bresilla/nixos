{ config, lib, pkgs, ... }:

let
  dir = "/data/attic";
  # The service's own command line, switched to a single garbage-collection pass.
  gcOnce = let
    cmd = builtins.replaceStrings [ "--mode ${config.services.atticd.mode}" ]
      [ "--mode garbage-collector-once" ] config.systemd.services.atticd.serviceConfig.ExecStart;
  in assert lib.assertMsg (lib.hasInfix "garbage-collector-once" cmd)
    "attic-gc: could not derive a garbage-collection command from atticd's ExecStart"; cmd;
in {
  # Attic binary cache: database and storage on the NVMe mirror; the signing secret
  # lives only in /var/lib/atticd.env on nest, never in git.
  services.atticd = {
    enable = true;
    environmentFile = "/var/lib/atticd.env";
    settings = {
      listen = "127.0.0.1:8081";
      api-endpoint = "https://cache.bresilla.com/";
      database.url = "sqlite://${dir}/server.db?mode=rwc";
      storage = { type = "local"; path = "${dir}/storage"; };
    };
  };

  # A fixed user, so files on the mirror keep their owner across boots.
  users.users.atticd = { isSystemUser = true; group = "atticd"; home = dir; };
  users.groups.atticd = { };
  systemd.services.atticd = {
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      ReadWritePaths = [ dir ];
      # As root, after the subvolume is mounted; a tmpfiles rule can run before that.
      ExecStartPre = [ "+${pkgs.coreutils}/bin/install -d -o atticd -g atticd -m 0750 ${dir}" ];
    };
    unitConfig.RequiresMountsFor = [ dir ];
  };

  # Attic frees at most 500 chunk files per pass and passes only every 12 hours,
  # so deleted data piles up; this repeats passes until none is left. Daily, and
  # once on every switch.
  systemd.services.attic-gc = {
    after = [ "atticd.service" ];
    wantedBy = [ "multi-user.target" ];
    startAt = "daily";
    unitConfig.RequiresMountsFor = [ dir ];
    environment.RUST_LOG = "info";
    path = [ pkgs.sqlite ];
    serviceConfig = {
      Type = "oneshot";
      User = "atticd";
      Group = "atticd";
      EnvironmentFile = "/var/lib/atticd.env";
      ReadWritePaths = [ dir ];
    };
    script = ''
      for pass in $(seq 1 200); do
        ${gcOnce}
        left=$(sqlite3 ${dir}/server.db "SELECT COUNT(*) FROM chunk WHERE state = 'D'")
        echo "pass $pass: $left deleted chunks left"
        [ "$left" -eq 0 ] && break
      done
    '';
  };

  # The read-only web page; it shows public caches only.
  systemd.services.cache-ui = {
    wantedBy = [ "multi-user.target" ];
    after = [ "atticd.service" ];
    unitConfig.RequiresMountsFor = [ dir ];
    environment = {
      CACHE_DB = "${dir}/server.db";
      CACHE_URL = "https://cache.bresilla.com";
      CACHE_LOGO = "${../../../configs/assets/bresilla.svg}";
      CACHE_PINS = "${../../../packages/pins.json}";
      CACHE_LISTEN = "127.0.0.1:8082";
    };
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./ui.py}";
      User = "atticd";
      Group = "atticd";
      Restart = "on-failure";
      ProtectSystem = "strict";
      ReadWritePaths = [ dir ];
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  # One port for both: the page at / and /-/, everything else is Attic itself.
  services.caddy = {
    enable = true;
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
  # hive's tunnel reaches it over the direct link; pushes come over NetBird, which is trusted.
  networking.firewall.interfaces.enp1s0.allowedTCPPorts = [ 8080 ];
}
