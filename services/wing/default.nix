# wing.bresilla.com inside its container: the page and its API on loopback, the login
# proxy in front of the pages, and Caddy on :8080 for the tunnel. /api skips the login
# proxy; the page answers it only with a token made on its settings page.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.wing;
  siteUi = import ../ui { inherit pkgs; };
  state = "/var/lib/wing";
in
{
  options.bresilla.services.wing = {
    domain = lib.mkOption { type = lib.types.str; };
    login = {
      issuer = lib.mkOption { type = lib.types.str; };
      client = lib.mkOption { type = lib.types.str; };
      envFile = lib.mkOption { type = lib.types.str; description = "Holds the login proxy's client and cookie secrets."; };
    };
  };

  config = {
    system.stateVersion = "26.05";
    users.users.wing = { isSystemUser = true; uid = 953; group = "wing"; home = state; };
    users.groups.wing.gid = 953;
    networking.firewall.allowedTCPPorts = [ 8080 ];
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];

    systemd.services.wing = {
      description = cfg.domain;
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        PYTHONPATH = "${siteUi}";
        WING_LISTEN = "127.0.0.1:8098";
        WING_DOMAIN = cfg.domain;
        WING_DATABASE = "${state}/wing.db";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./wing.py}";
        Restart = "on-failure";
        User = "wing";
        Group = "wing";
        StateDirectory = "wing";
        StateDirectoryMode = "0700";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        CapabilityBoundingSet = [ "" ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
      };
    };

    systemd.services.caddy.serviceConfig = {
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = lib.mkForce "strict";
      ProtectHome = true;
      CapabilityBoundingSet = [ "" ];
      LockPersonality = true;
    };
    services.caddy = {
      enable = true;
      virtualHosts."http://:8080".extraConfig = ''
        ${import ../headers.nix}
        request_header -X-Forwarded-User
        request_header -X-Forwarded-Preferred-Username
        request_header -X-Forwarded-Groups
        request_header -X-Forwarded-Email
        handle /oauth2/* {
          reverse_proxy 127.0.0.1:4180
        }
        handle /api/* {
          reverse_proxy 127.0.0.1:8098
        }
        handle {
          route {
            forward_auth 127.0.0.1:4180 {
              uri /oauth2/auth
              copy_headers X-Auth-Request-Preferred-Username>X-Forwarded-Preferred-Username
              @out status 401
              handle_response @out {
                redir * /oauth2/start?rd={uri}
              }
            }
            reverse_proxy 127.0.0.1:8098
          }
        }
      '';
    };

    systemd.services.oauth2-proxy = {
      after = [ "network-online.target" ];
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
      upstream = [ "http://127.0.0.1:8098" ];
      email.domains = [ "*" ];
      reverseProxy = true;
      trustedProxyIP = [ "127.0.0.1" ];
      scope = "openid email profile";
      cookie = { name = "_wing_login"; secure = true; expire = "720h0m0s"; };
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
