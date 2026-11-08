{ pkgs, ... }:
let
  address = "10.231.3.2";
  sites = {
    gitea = { name = "git"; landing = "https://git.bresilla.com"; callback = "https://git.bresilla.com/user/oauth2/id/callback"; group = "git"; };
    cache = { name = "cache"; landing = "https://cache.bresilla.com"; callback = "https://cache.bresilla.com/oauth2/callback"; group = "cache"; };
    build = { name = "build"; landing = "https://build.bresilla.com"; callback = "https://build.bresilla.com/oauth2/callback"; group = "build"; };
  };
  root = c: "/var/lib/nixos-containers/${c}/var/lib/oidc";
in {
  # Public through the Cloudflare tunnel: the one login for git, cache and build.
  services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress."id.bresilla.com" = "http://${address}:80";

  networking.nat = { enable = true; internalInterfaces = [ "ve-id" ]; externalInterface = "enp4s0"; };
  # Hive sets this link from outside, so the container needs no network control.
  hive.containerNet.id = { host = "10.231.3.1"; local = address; };

  # Each site's login secret, made once on hive and never in git: Kanidm holds all
  # of them, and each site the one it signs in with (cache and build also a cookie
  # secret for their login proxy). Copied in before any of these containers starts.
  systemd.services.oidc-secrets = {
    description = "Login secrets for id.bresilla.com and its sites";
    before = map (c: "container@${c}.service") [ "id" "gitea" "cache" "ci" ];
    requiredBy = map (c: "container@${c}.service") [ "id" "gitea" "cache" "ci" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = [ pkgs.openssl pkgs.coreutils ];
    script = ''
      d=/var/lib/oidc-secrets
      install -d -m 0700 "$d"
      for s in gitea cache build cache-cookie build-cookie; do
        [ -s "$d/$s" ] || (umask 077; openssl rand -hex 16 > "$d/$s")
      done
      for s in gitea cache build; do install -D -m 0600 "$d/$s" "${root "id"}/$s"; done
      install -D -m 0600 "$d/gitea" "${root "gitea"}/gitea"
      for pair in cache:cache ci:build; do
        c=''${pair%%:*} s=''${pair#*:}
        install -d -m 0700 "/var/lib/nixos-containers/$c/var/lib/oidc"
        (umask 077; printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\nOAUTH2_PROXY_COOKIE_SECRET=%s\n' \
          "$(< "$d/$s")" "$(< "$d/$s-cookie")" > "/var/lib/nixos-containers/$c/var/lib/oidc/proxy.env")
      done
    '';
  };

  # Enrolment links for id.bresilla.com from hive: `sudo id-enroll <name>`.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "id-enroll" ''
      exec ${pkgs.nixos-container}/bin/nixos-container run id -- id-enroll "$@"
    '')
  ];

  containers.id = {
    autoStart = true;
    privateUsers = 524288;
    # Maps the container's own files on the fly instead of rewriting their owners.
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    config = { lib, ... }: {
      imports = [ ../../../shared/services/server/id ];
      bresilla.services.id = {
        domain = "id.bresilla.com";
        admin = { name = "bresilla"; displayName = "Trim Bresilla"; mail = "kushtrimbresilla@gmail.com"; };
      };
      # Per site: <site>_users may sign in, <site>_admins may change things, which
      # the site reads from a <site>_role claim of "admin".
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
        }) sites;
      };
    };
  };
}
