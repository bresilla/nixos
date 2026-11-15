# Vaultwarden, as vault.bresilla.com: reached only over the overlay network, signing
# in only through id.bresilla.com. The vault itself is still encrypted with each
# person's master password, which neither this server nor id ever sees.
# Caddy in front gets its certificate from bresilla's own CA (cert.bresilla.com);
# the web vault is the stock build with the shared look added (vault.css, site.js).
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.vault;
  siteUi = import ../ui { inherit pkgs; };
  tls = "/var/lib/vault-tls";
  version = builtins.substring 0 12 (builtins.hashString "sha256"
    "${siteUi}:${builtins.hashFile "sha256" ./vault.css}:${builtins.hashFile "sha256" ./adapter.js}");
  theme = pkgs.runCommand "vault-theme" { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir -p $out
    cat ${siteUi}/tokens.css ${siteUi}/id-header.css ${./vault.css} > $out/vault.css
    logo=$(sed '1{/^<?xml/d}' ${siteUi}/logo.svg \
      | sed -E 's/fill="#[0-9a-fA-F]+"/fill="currentColor"/g' | jq -Rs .)
    substitute ${./adapter.js} adapter.js --replace-fail @LOGO@ "$logo"
    cat ${siteUi}/theme.js adapter.js > $out/site.js
  '';
  # The stock web vault, its page loading the shared look before its own app.
  webvault = pkgs.runCommand "vaultwarden-webvault-bresilla" { } ''
    src=${pkgs.vaultwarden.webvault}/share/vaultwarden/vault
    dst=$out/share/vaultwarden/vault
    mkdir -p $dst
    for f in $src/*; do ln -s "$f" "$dst/$(basename "$f")"; done
    rm $dst/index.html
    substitute $src/index.html $dst/index.html --replace-fail '</head>' \
      '<link rel="stylesheet" href="bresilla/vault.css?v=${version}"/><script defer src="bresilla/site.js?v=${version}"></script></head>'
    ln -s ${theme} $dst/bresilla
  '';
in
{
  options.bresilla.services.vault = {
    domain = lib.mkOption { type = lib.types.str; description = "The vault's name, resolved only inside."; };
    login = {
      authority = lib.mkOption { type = lib.types.str; description = "The provider's issuer URL, without /.well-known."; };
      client = lib.mkOption { type = lib.types.str; description = "The client name at the provider."; };
      envFile = lib.mkOption { type = lib.types.str; description = "Holds SSO_CLIENT_SECRET."; };
    };
    ca = lib.mkOption {
      default = null;
      description = "The CA Caddy gets the certificate from over ACME; without it, a self-signed one.";
      type = lib.types.nullOr (lib.types.submodule {
        options.directory = lib.mkOption { type = lib.types.str; description = "Its ACME directory URL."; };
        options.root = lib.mkOption { type = lib.types.path; description = "Its root certificate."; };
        options.name = lib.mkOption { type = lib.types.str; };
        options.address = lib.mkOption { type = lib.types.str; };
      });
    };
  };

  config = {
    system.stateVersion = "26.05";
    networking.firewall.allowedTCPPorts = [ 443 ];
    # The host's resolver listens on its own loopback, which this network can't reach.
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];

    services.vaultwarden = {
      enable = true;
      dbBackend = "sqlite";
      # A nightly copy of the database and keys; hive takes it to nest.
      backupDir = "/var/backup/vaultwarden";
      webVaultPackage = webvault;
      environmentFile = cfg.login.envFile;
      config = {
        DOMAIN = "https://${cfg.domain}";
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8222;
        IP_HEADER = "X-Forwarded-For";
        # Accounts come only from id.bresilla.com, and signing in goes only there.
        SSO_ENABLED = true;
        SSO_ONLY = true;
        SSO_AUTHORITY = cfg.login.authority;
        SSO_CLIENT_ID = cfg.login.client;
        SSO_SCOPES = "email profile";
        SSO_SIGNUPS_MATCH_EMAIL = false;
        SIGNUPS_ALLOWED = false;
        INVITATIONS_ALLOWED = false;
        PASSWORD_HINTS_ALLOWED = false;
        SHOW_PASSWORD_HINT = false;
        # No ADMIN_TOKEN: the /admin page stays off, so it is no way in either.
      };
    };

    # Before the CA exists: a self-signed stand-in, so Caddy can start.
    systemd.services.vault-tls = lib.mkIf (cfg.ca == null) {
      description = "vault.bresilla.com's stand-in certificate";
      before = [ "caddy.service" ];
      requiredBy = [ "caddy.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        install -d -m 0750 -o root -g caddy ${tls}
        [ -s ${tls}/key.pem ] && exit 0
        ${pkgs.openssl}/bin/openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
          -subj "/CN=${cfg.domain}" -addext "subjectAltName=DNS:${cfg.domain}" \
          -keyout ${tls}/key.pem -out ${tls}/fullchain.pem
        chgrp caddy ${tls}/key.pem ${tls}/fullchain.pem
        chmod 0640 ${tls}/key.pem ${tls}/fullchain.pem
      '';
    };
    # The CA by its name, here and not in any public DNS.
    networking.hosts = lib.mkIf (cfg.ca != null) { ${cfg.ca.address} = [ cfg.ca.name ]; };

    services.caddy = {
      enable = true;
      globalConfig = "auto_https disable_redirects";
      virtualHosts."${cfg.domain}:443".extraConfig = ''
        ${if cfg.ca == null then "tls ${tls}/fullchain.pem ${tls}/key.pem" else ''
        # A one-day certificate from bresilla's CA, renewed by Caddy; the CA checks
        # this very port (TLS-ALPN), as nothing serves plain HTTP here.
        tls {
          issuer acme {
            dir ${cfg.ca.directory}
            trusted_roots ${cfg.ca.root}
            disable_http_challenge
          }
        }''}
        # The shared rules, except framing: the web vault frames its own helper
        # pages, and Vaultwarden sets frame-ancestors itself.
        header {
          defer
          Strict-Transport-Security "max-age=63072000"
          X-Content-Type-Options nosniff
          Referrer-Policy same-origin
        }
        reverse_proxy 127.0.0.1:8222
      '';
    };
  };
}
