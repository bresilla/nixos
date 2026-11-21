# status.bresilla.com inside its container: the page, the login proxy in front of it,
# and Caddy with a certificate from bresilla's CA. It reads the reports hive puts in
# /var/lib/status and nothing else.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.status;
  siteUi = import ../ui { inherit pkgs; };
in
{
  options.bresilla.services.status = {
    domain = lib.mkOption { type = lib.types.str; };
    login = {
      issuer = lib.mkOption { type = lib.types.str; };
      client = lib.mkOption { type = lib.types.str; };
      envFile = lib.mkOption { type = lib.types.str; description = "Holds the login proxy's client and cookie secrets."; };
    };
    ca = lib.mkOption {
      default = null;
      type = lib.types.nullOr (lib.types.submodule {
        options.directory = lib.mkOption { type = lib.types.str; };
        options.root = lib.mkOption { type = lib.types.path; };
        options.name = lib.mkOption { type = lib.types.str; };
        options.address = lib.mkOption { type = lib.types.str; };
      });
    };
  };

  config = {
    system.stateVersion = "26.05";
    # btrbk names snapshots in nest's local time; the page reads them in the same.
    time.timeZone = "Europe/Amsterdam";
    networking.firewall.allowedTCPPorts = [ 443 ];
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
    networking.hosts = lib.mkIf (cfg.ca != null) { ${cfg.ca.address} = [ cfg.ca.name ]; };

    systemd.services.status-ui = {
      description = cfg.domain;
      wantedBy = [ "multi-user.target" ];
      environment = {
        PYTHONPATH = "${siteUi}";
        STATUS_DATA = "/var/lib/status";
        STATUS_LISTEN = "127.0.0.1:8093";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./status.py}";
        Restart = "on-failure";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        CapabilityBoundingSet = [ "" ];
        RestrictAddressFamilies = [ "AF_INET" ];
        LockPersonality = true;
      };
    };

    services.caddy = {
      enable = true;
      globalConfig = "auto_https disable_redirects";
      virtualHosts."${cfg.domain}:443".extraConfig = ''
        ${if cfg.ca == null then "tls internal" else ''
        # A one-day certificate from bresilla's CA; it checks this very port (TLS-ALPN).
        tls {
          issuer acme {
            dir ${cfg.ca.directory}
            trusted_roots ${cfg.ca.root}
            disable_http_challenge
          }
        }''}
        ${import ../headers.nix}
        handle /oauth2/* {
          reverse_proxy 127.0.0.1:4180
        }
        # The name comes only from the login proxy; route keeps the stripping first.
        handle {
          route {
            request_header -X-Forwarded-User
            request_header -X-Forwarded-Preferred-Username
            request_header -X-Forwarded-Groups
            request_header -X-Forwarded-Email
            forward_auth 127.0.0.1:4180 {
              uri /oauth2/auth
              copy_headers X-Auth-Request-Preferred-Username>X-Forwarded-Preferred-Username
              @out status 401
              handle_response @out {
                redir * /oauth2/start?rd={uri}
              }
            }
            reverse_proxy 127.0.0.1:8093
          }
        }
      '';
    };

    systemd.services.oauth2-proxy = {
      after = [ "network-online.target" "resolvconf.service" ];
      wants = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      serviceConfig.RestartSec = 10;
    };
    services.oauth2-proxy = {
      enable = true;
      provider = "oidc";
      clientID = cfg.login.client;
      keyFile = cfg.login.envFile;
      oidcIssuerUrl = cfg.login.issuer;
      redirectURL = "https://${cfg.domain}/oauth2/callback";
      httpAddress = "http://127.0.0.1:4180";
      upstream = [ "http://127.0.0.1:8093" ];
      email.domains = [ "*" ];
      reverseProxy = true;
      trustedProxyIP = [ "127.0.0.1" ];
      scope = "openid email profile";
      cookie = { name = "_status_login"; secure = true; expire = "24h0m0s"; };
      approvalPrompt = "auto";
      passBasicAuth = false;
      extraConfig = {
        skip-provider-button = true;
        whitelist-domain = builtins.elemAt (lib.splitString "/" cfg.login.issuer) 2;
        code-challenge-method = "S256";
        set-xauthrequest = true;
        insecure-oidc-allow-unverified-email = true;
      };
    };
  };
}
