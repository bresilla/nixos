{ config, lib, pkgs, ... }:
let
  mnt = config.bresilla.server.storage.mount;
  cfg = config.bresilla.server.ci;
  address = "10.231.2.2";
in {
  options.bresilla.server.ci.enable = lib.mkEnableOption "CI, build.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "ci" ];
    bresilla.server.keep.ci = [ "/var/lib/nixos-containers/ci/var/lib/ci/secrets" "/var/lib/nixos-containers/ci/var/lib/murosd-secrets" ];
    bresilla.server.keepTo.ci = "${mnt}/build/config";
    # Public through the Cloudflare tunnel.
    # Its repositories, builders and secrets are set on build.bresilla.com.
    services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress."build.bresilla.com" = "http://${address}:80";

    networking.nat = { enable = true; internalInterfaces = [ "ve-ci" ]; };
    # Hive sets this link from outside, so the container needs no network control.
    bresilla.server.containerNet.ci = { host = "10.231.2.1"; local = address; };

    # murosd's and the page's databases, copied whole each night to build's share
    # on nest for 14 days; SQLite's own backup is safe while they are in use.
    bresilla.server.shares."build" = "build";
    systemd.services.build-backup = {
      description = "Copy build.bresilla.com's databases to nest";
      unitConfig.RequiresMountsFor = [ "${mnt}/build" ];
      serviceConfig = { Type = "oneshot"; Nice = 10; };
      path = [ pkgs.sqlite pkgs.coreutils pkgs.findutils ];
      script = ''
        root=/var/lib/nixos-containers/ci/var/lib
        dst=${mnt}/build/data/$(date -u +%F)
        install -d -m 0700 "$dst"
        for db in "$root"/murosd/*.db "$root"/muros-ui/*.db; do
          [ -f "$db" ] || continue
          sqlite3 "$db" ".backup '$dst/$(basename "$(dirname "$db")")-$(basename "$db")'"
        done
        find ${mnt}/build/data -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
      '';
    };
    systemd.timers.build-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "03:40 UTC"; Persistent = true; };
    };

    containers.ci = {
      autoStart = true;
      # Maps the container's own files on the fly instead of rewriting their owners.
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      config = {
        imports = [ ./. ];
        bresilla.services.ci = {
          domain = "build.bresilla.com";
          # Sign in with id.bresilla.com; hive puts the login secrets here.
          login = {
            issuer = "https://id.bresilla.com/oauth2/openid/build";
            client = "build";
            envFile = "/var/lib/oidc/proxy.env";
            adminClaim = "build_role";
          };
          cache = "http://10.231.1.2:8080";
          proxy = "10.231.2.1";
        };
      };
    };
  };
}
