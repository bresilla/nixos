# Kanidm: the one login for git, cache and build, as id.bresilla.com. People and
# groups are declared here; each site signs in through an OAuth2 client of its own.
# nginx in front serves Kanidm's own hooks for its look (override.css, style.js,
# the logo) in the style of the other sites.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.id;
  tls = "/var/lib/kanidm-tls";
  secrets = "/var/lib/kanidm-secrets";
  # Cloudflare would otherwise keep an old look for hours after a change.
  noCache = "add_header Cache-Control \"no-cache\";";
  theme = pkgs.runCommand "id-theme" { } ''
    mkdir -p $out
    cp ${./override.css} $out/override.css
    cat ${config.services.kanidm.package}/ui/hpkg/style.js ${./hue.js} \
      | sed "s/@VERSION@/${builtins.substring 0 12 (builtins.hashFile "sha256" ./override.css)}/" > $out/style.js
    cp ${../../../../configs/assets/bresilla.svg} $out/logo.svg
  '';
in
{
  options.bresilla.services.id = {
    domain = lib.mkOption { type = lib.types.str; description = "Kanidm's domain; permanent, part of every account name."; };
    displayName = lib.mkOption { type = lib.types.str; default = "bresilla"; description = "The name every page shows."; };
    admin = {
      name = lib.mkOption { type = lib.types.str; };
      displayName = lib.mkOption { type = lib.types.str; };
      mail = lib.mkOption { type = lib.types.str; };
    };
  };

  config = {
    system.stateVersion = "26.05";
    networking.firewall.allowedTCPPorts = [ 80 ];
    # The host's resolver listens on its own loopback, which this network can't reach.
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];

    # Kanidm only speaks TLS; Cloudflare holds the real certificate, so inside it is
    # a self-signed one, made once.
    systemd.services.kanidm-tls = {
      description = "Kanidm's internal certificate";
      before = [ "kanidm.service" ];
      requiredBy = [ "kanidm.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        # The admin password, made once and kept only here; provisioning sets it.
        install -d -m 0700 -o kanidm -g kanidm ${secrets}
        [ -s ${secrets}/admin ] || (umask 077; ${pkgs.openssl}/bin/openssl rand -hex 24 > ${secrets}/admin)
        chown kanidm:kanidm ${secrets}/admin
        [ -s ${tls}/key.pem ] && exit 0
        mkdir -p ${tls}
        ${pkgs.openssl}/bin/openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
          -subj "/CN=${cfg.domain}" -addext "subjectAltName=DNS:${cfg.domain},IP:127.0.0.1" \
          -keyout ${tls}/key.pem -out ${tls}/chain.pem
        chown -R kanidm:kanidm ${tls}
        chmod 0600 ${tls}/key.pem
      '';
    };

    services.kanidm = {
      package = pkgs.kanidmWithSecretProvisioning_1_12;
      server.enable = true;
      server.settings = {
        inherit (cfg) domain;
        origin = "https://${cfg.domain}";
        bindaddress = "127.0.0.1:8443";
        tls_chain = "${tls}/chain.pem";
        tls_key = "${tls}/key.pem";
        # nginx is the only client and adds the visitor's address.
        http_client_address_info.x-forward-for = [ "127.0.0.1" ];
        online_backup = { path = "/var/lib/kanidm/backups"; schedule = "00 03 * * *"; versions = 7; };
      };
      provision = {
        enable = true;
        instanceUrl = "https://127.0.0.1:8443";
        acceptInvalidCerts = true;
        adminPasswordFile = "${secrets}/admin";
        persons.${cfg.admin.name} = {
          inherit (cfg.admin) displayName;
          mailAddresses = [ cfg.admin.mail ];
        };
        # Who may do what on each site; the sites read these from the login.
        groups = lib.genAttrs [ "git_admins" "cache_admins" "build_admins" ] (_: { members = [ cfg.admin.name ]; });
      };
    };

    # The name every page shows, set as admin once Kanidm runs.
    systemd.services.kanidm-domain = {
      description = "Kanidm's display name";
      after = [ "kanidm.service" ];
      requires = [ "kanidm.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RuntimeDirectory = "kanidm-domain"; };
      environment = {
        HOME = "/run/kanidm-domain";
        KANIDM_URL = "https://127.0.0.1:8443";
        KANIDM_ACCEPT_INVALID_CERTS = "true";
        KANIDM_NAME = "admin";
      };
      script = ''
        KANIDM_PASSWORD=$(< ${secrets}/admin) ${config.services.kanidm.package}/bin/kanidm login
        ${config.services.kanidm.package}/bin/kanidm system domain set-displayname ${lib.escapeShellArg cfg.displayName}
      '';
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts.${cfg.domain} = {
        default = true;
        locations = {
          "/" = {
            proxyPass = "https://127.0.0.1:8443";
            extraConfig = ''
              proxy_ssl_verify off;
              proxy_ssl_server_name on;
              proxy_ssl_name ${cfg.domain};
            '';
          };
          # Kanidm's own hooks for its look, and the logo.
          "= /pkg/override.css" = { alias = "${theme}/override.css"; extraConfig = noCache; };
          "= /pkg/style.js" = { alias = "${theme}/style.js"; extraConfig = noCache; };
          "= /pkg/img/logo-square.svg" = { alias = "${theme}/logo.svg"; extraConfig = noCache; };
        };
      };
    };
  };
}
