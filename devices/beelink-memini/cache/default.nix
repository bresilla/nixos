{ lib, pkgs, ... }:

let
  dir = "/data/attic";
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

  # The read-only web page; it shows public caches only.
  systemd.services.cache-ui = {
    wantedBy = [ "multi-user.target" ];
    after = [ "atticd.service" ];
    unitConfig.RequiresMountsFor = [ dir ];
    environment = {
      CACHE_DB = "${dir}/server.db";
      CACHE_URL = "https://cache.bresilla.com";
      CACHE_LOGO = "${../../../configs/assets/bresilla.svg}";
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
