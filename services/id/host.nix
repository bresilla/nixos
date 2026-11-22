{ config, lib, pkgs, ... }:
let
  mnt = config.bresilla.server.storage.mount;
  cfg = config.bresilla.server.id;
  address = "10.231.3.2";
  sites = {
    gitea = { name = "git"; landing = "https://git.bresilla.com"; callback = "https://git.bresilla.com/user/oauth2/id/callback"; group = "git"; };
    cache = { name = "cache"; landing = "https://cache.bresilla.com"; callback = "https://cache.bresilla.com/oauth2/callback"; group = "cache"; };
    build = { name = "build"; landing = "https://build.bresilla.com"; callback = "https://build.bresilla.com/oauth2/callback"; group = "build"; };
    s3 = { name = "s3"; landing = "https://s3.bresilla.com"; callback = "https://s3.bresilla.com/rustfs/admin/v3/oidc/callback/default"; group = "s3"; };
    vault = { name = "vault"; landing = "https://vault.bresilla.com"; callback = "https://vault.bresilla.com/identity/connect/oidc-signin"; group = "vault"; };
    net = { name = "net"; landing = "https://net.bresilla.com"; callback = "https://net.bresilla.com/oauth2/callback"; group = "net"; };
    status = { name = "status"; landing = "https://status.bresilla.com"; callback = "https://status.bresilla.com/oauth2/callback"; group = "status"; };
  };
  root = c: "/var/lib/nixos-containers/${c}/var/lib/oidc";
in {
  options.bresilla.server.id.enable = lib.mkEnableOption "the login, id.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "id" ];
    bresilla.server.keep.logins = [ "/var/lib/oidc-secrets" ];
    bresilla.server.keepTo.logins = "${mnt}/id/config";
    # Public through the Cloudflare tunnel: the one login for git, cache and build.
    bresilla.server.tunnel.ingress."id.bresilla.com" = "http://${address}:80";

    networking.nat = { enable = true; internalInterfaces = [ "ve-id" ]; };
    # Hive sets this link from outside, so the container needs no network control.
    bresilla.server.containerNet.id = { host = "10.231.3.1"; local = address; };

    # Each site's login secret, made once on hive and never in git: Kanidm holds all
    # of them, and each site the one it signs in with (cache and build also a cookie
    # secret for their login proxy). Copied in before any of these containers starts.
    systemd.services.oidc-secrets = {
      description = "Login secrets for id.bresilla.com and its sites";
      before = map (c: "container@${c}.service") [ "id" "gitea" "cache" "ci" "s3" "vault" "innernet" "status" ];
      requiredBy = map (c: "container@${c}.service") [ "id" "gitea" "cache" "ci" "s3" "vault" "innernet" "status" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      path = [ pkgs.openssl pkgs.coreutils ];
      script = ''
        d=/var/lib/oidc-secrets
        install -d -m 0700 "$d"
        for s in gitea cache build s3 vault net status cache-cookie build-cookie net-cookie status-cookie; do
          [ -s "$d/$s" ] || (umask 077; openssl rand -hex 16 > "$d/$s")
        done
        for s in gitea cache build s3 vault net status; do install -D -m 0600 "$d/$s" "${root "id"}/$s"; done
        install -D -m 0600 "$d/gitea" "${root "gitea"}/gitea"
        install -d -m 0700 "${root "s3"}"
        (umask 077; printf 'RUSTFS_IDENTITY_OPENID_CLIENT_SECRET=%s\n' "$(< "$d/s3")" > "${root "s3"}/s3.env")
        install -d -m 0700 "${root "vault"}"
        (umask 077; printf 'SSO_CLIENT_SECRET=%s\n' "$(< "$d/vault")" > "${root "vault"}/vault.env")
        for pair in cache:cache ci:build innernet:net status:status; do
          c=''${pair%%:*} s=''${pair#*:}
          install -d -m 0700 "/var/lib/nixos-containers/$c/var/lib/oidc"
          (umask 077; printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\nOAUTH2_PROXY_COOKIE_SECRET=%s\n' \
            "$(< "$d/$s")" "$(< "$d/$s-cookie")" > "/var/lib/nixos-containers/$c/var/lib/oidc/proxy.env")
        done
      '';
    };

    # Kanidm's nightly backups (03:00 UTC, inside the container) are copied to nest and
    # kept there for 3 days. The container itself never needs nest, so signing in
    # keeps working when nest is down; only that night's copy is missed.
    bresilla.server.shares."id" = "id";
    systemd.services.id-backup = {
      description = "Copy id.bresilla.com's backups to nest";
      unitConfig.RequiresMountsFor = [ "${mnt}/id" ];
      serviceConfig = { Type = "oneshot"; Nice = 10; };
      path = [ pkgs.coreutils pkgs.findutils ];
      script = ''
        src=/var/lib/nixos-containers/id/var/lib/kanidm/backups
        dst=${mnt}/id/data/kanidm
        install -d -m 0700 "$dst"
        for f in "$src"/*; do
          [ -f "$f" ] || continue
          [ -e "$dst/$(basename "$f")" ] || cp --preserve=timestamps "$f" "$dst/"
        done
        find "$dst" -maxdepth 1 -type f -mtime +3 -delete
      '';
    };
    systemd.timers.id-backup = {
      wantedBy = [ "timers.target" ];
      # Kanidm reads its schedule as UTC, so this does too.
      timerConfig = { OnCalendar = "03:20 UTC"; Persistent = true; };
    };

    # Enrolment links for id.bresilla.com from hive: `sudo id-enroll <name>`.
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "id-enroll" ''
        exec ${pkgs.nixos-container}/bin/nixos-container run id -- id-enroll "$@"
      '')
    ];

    containers.id = {
      autoStart = true;
      # Maps the container's own files on the fly instead of rewriting their owners.
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      config = { lib, ... }: {
        imports = [ ./. ];
        bresilla.services.id = {
          domain = "id.bresilla.com";
          proxy = "10.231.3.1";
          admin = { name = "bresilla"; displayName = "Trim Bresilla"; mail = "trim.bresilla@gmail.com"; };
        };
        # Per site: <site>_users may sign in, <site>_admins may change things, which
        # the site reads from a <site>_role claim of "admin". s3 instead reads the
        # names of RustFS policies from s3_policy.
        services.kanidm.provision = {
          groups = lib.listToAttrs (lib.concatMap (s: [
            { name = "${s.group}_users"; value.members = [ "bresilla" ]; }
            { name = "${s.group}_admins"; value.members = [ "bresilla" ]; }
          ]) (builtins.attrValues sites));
          systems.oauth2 = lib.mapAttrs (client: s: {
            displayName = s.name;
            originUrl = s.callback;
            originLanding = s.landing;
            basicSecretFile = "/var/lib/kanidm-secrets/${client}";
            preferShortUsername = true;
            scopeMaps."${s.group}_users" = [ "openid" "email" "profile" ];
            claimMaps."${s.group}_role".valuesByGroup."${s.group}_admins" = [ "admin" ];
          } // lib.optionalAttrs (client == "gitea") {
            # gitea's OIDC client signs in without PKCE and expects RS256 tokens.
            allowInsecureClientDisablePkce = true;
            enableLegacyCrypto = true;
          } // lib.optionalAttrs (client == "s3") {
            claimMaps.s3_policy.valuesByGroup = { s3_users = [ "readwrite" ]; s3_admins = [ "consoleAdmin" ]; };
          }) sites;
        };
      };
    };
  };
}
