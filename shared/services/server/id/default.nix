# Kanidm: the one login for git, cache and build, as id.bresilla.com. People and
# groups are declared here; each site signs in through an OAuth2 client of its own.
# Caddy in front serves Kanidm's own hooks for its look (override.css, style.js,
# the logo) in the style of the other sites.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.id;
  siteUi = import ../ui { inherit pkgs; };
  tls = "/var/lib/kanidm-tls";
  secrets = "/var/lib/kanidm-secrets";
  theme = pkgs.runCommand "id-theme" { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir -p $out
    cat ${siteUi}/tokens.css ${siteUi}/id-header.css ${./override.css} > $out/override.css
    logo=$(sed '1{/^<?xml/d}' ${siteUi}/logo.svg \
      | sed -E 's/fill="#[0-9a-fA-F]+"/fill="currentColor"/g' | jq -Rs .)
    substitute ${./hue.js} adapter.js \
      --replace-fail @VERSION@ ${builtins.substring 0 12 (builtins.hashString "sha256" "${siteUi}:${builtins.hashFile "sha256" ./override.css}")} \
      --replace-fail @LOGO@ "$logo"
    cat ${config.services.kanidm.package}/ui/hpkg/style.js ${siteUi}/theme.js adapter.js > $out/style.js
    cp ${siteUi}/logo.svg $out/logo.svg
  '';
in
{
  options.bresilla.services.id = {
    domain = lib.mkOption { type = lib.types.str; description = "Kanidm's domain; permanent, part of every account name."; };
    displayName = lib.mkOption { type = lib.types.str; default = "bresilla"; description = "The name every page shows."; };
    proxy = lib.mkOption { type = lib.types.str; description = "Address of the proxy in front of it, trusted for the client's address."; };
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
      # Runs every start, so a secret hive replaced reaches Kanidm too.
      requiredBy = [ "kanidm.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        # The admin password, made once and kept only here; provisioning sets it.
        install -d -m 0700 -o kanidm -g kanidm ${secrets}
        for a in admin idm_admin; do
          [ -s ${secrets}/$a ] || (umask 077; ${pkgs.openssl}/bin/openssl rand -hex 24 > ${secrets}/$a)
        done
        chown kanidm:kanidm ${secrets}/admin ${secrets}/idm_admin
        # The sites' login secrets, as hive delivered them, readable by Kanidm.
        for f in /var/lib/oidc/*; do
          if [ -f "$f" ]; then install -m 0600 -o kanidm -g kanidm "$f" "${secrets}/$(basename "$f")"; fi
        done
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
        # Caddy is the only client and adds the visitor's address.
        http_client_address_info.x-forward-for = [ "127.0.0.1" ];
        online_backup = { path = "/var/lib/kanidm/backups"; schedule = "00 03 * * *"; versions = 7; };
      };
      provision = {
        enable = true;
        instanceUrl = "https://127.0.0.1:8443";
        acceptInvalidCerts = true;
        adminPasswordFile = "${secrets}/admin";
        idmAdminPasswordFile = "${secrets}/idm_admin";
        persons.${cfg.admin.name} = {
          inherit (cfg.admin) displayName;
          mailAddresses = [ cfg.admin.mail ];
        };
      };
    };

    # A one-day link where a person sets their passkey or password: `id-enroll <name>`.
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "id-enroll" ''
        name=''${1:?usage: id-enroll <name>}
        HOME=$(mktemp -d)
        export HOME KANIDM_URL=https://127.0.0.1:8443 KANIDM_ACCEPT_INVALID_CERTS=true KANIDM_NAME=idm_admin
        KANIDM_PASSWORD=$(< ${secrets}/idm_admin) ${config.services.kanidm.package}/bin/kanidm login >/dev/null 2>&1
        ${config.services.kanidm.package}/bin/kanidm person credential create-reset-token --ttl 86400 "$name" 2>&1 \
          | grep -v "WARN" | sed "s|https://127.0.0.1:8443|https://${cfg.domain}|"
        rm -rf "$HOME"
      '')
    ];

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

    services.caddy = {
      enable = true;
      # The tunnel says who the visitor is and that they used https.
      globalConfig = ''
        servers {
          trusted_proxies static ${cfg.proxy}/32
        }
      '';
      virtualHosts."http://:80".extraConfig = let
        # Kanidm's own hooks for its look, and the logo. Store files all carry the
        # same date, so nothing lets Cloudflare or a browser keep an old look.
        file = path: name: ''
          handle ${path} {
            header Cache-Control no-cache
            header -ETag
            header -Last-Modified
            rewrite * /${name}
            root * ${theme}
            file_server
          }
        '';
      in ''
        ${import ../headers.nix}
        ${file "/pkg/override.css" "override.css"}
        ${file "/pkg/style.js" "style.js"}
        ${file "/pkg/img/logo-square.svg" "logo.svg"}
        handle {
          reverse_proxy https://127.0.0.1:8443 {
            transport http {
              tls_insecure_skip_verify
              tls_server_name ${cfg.domain}
            }
          }
        }
      '';
    };
  };
}
