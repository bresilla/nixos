# search.bresilla.com inside its container: searx on loopback, the page over it, the login
# proxy in front of both, and Caddy on :8080 for the tunnel. Only signed-in people search.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.search;
  siteUi = import ../ui { inherit pkgs; };
  state = "/var/lib/search";
  # Off in searx's standard profile, and answering from hive's address (tested 2026-11-27);
  # Brave, Mojeek, Qwant, Yandex and Swisscows refuse it with a CAPTCHA or a 429.
  extra = [ "duckduckgo" "bing" "yahoo" "bing_images" "bing news" "duckduckgo_definitions"
            "duckduckgo_weather" "deviantart" "sepiasearch" "imdb" ];
  # Layered over searx's own standard profile.
  settings = (pkgs.formats.toml { }).generate "searx.toml" {
    engines = map (name: { inherit name; disabled = false; }) extra;
    general = { instance_name = "search"; enable_metrics = false; };
    server = {
      bind_address = "127.0.0.1";
      port = 8095;
      base_url = "https://${cfg.domain}/";
      limiter = false;
      image_proxy = true;
      public_instance = false;
    };
    search = { autocomplete = "duckduckgo"; formats = [ "json" "html" ]; };
  };
  sandbox = {
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
    User = "search";
    Group = "search";
    StateDirectory = "search";
  };
in
{
  options.bresilla.services.search = {
    domain = lib.mkOption { type = lib.types.str; };
    searx = lib.mkOption { type = lib.types.package; };
    login = {
      issuer = lib.mkOption { type = lib.types.str; };
      client = lib.mkOption { type = lib.types.str; };
      envFile = lib.mkOption { type = lib.types.str; description = "Holds the login proxy's client and cookie secrets."; };
    };
  };

  config = {
    system.stateVersion = "26.05";
    users.users.search = { isSystemUser = true; uid = 952; group = "search"; home = state; };
    users.groups.search.gid = 952;
    networking.firewall.allowedTCPPorts = [ 8080 ];
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];

    # The key searx signs image and favicon addresses with; the page signs with it too.
    systemd.services.search-secret = {
      description = "searx's signing key";
      before = [ "searx.service" "search-ui.service" ];
      requiredBy = [ "searx.service" "search-ui.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; } // sandbox;
      script = ''
        [ -s ${state}/secret ] || (umask 077; ${pkgs.openssl}/bin/openssl rand -hex 32 > ${state}/secret)
      '';
    };

    systemd.services.searx = {
      description = "searx for ${cfg.domain}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      script = ''
        SEARXNG_SECRET=$(< ${state}/secret) exec ${lib.getExe cfg.searx} --config ${settings}
      '';
      serviceConfig = sandbox // {
        Restart = "on-failure";
        RestartSec = 5;
        MemoryDenyWriteExecute = true;
      };
    };

    systemd.services.search-ui = {
      description = cfg.domain;
      after = [ "searx.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        PYTHONPATH = "${siteUi}";
        SEARCH_LISTEN = "127.0.0.1:8096";
        SEARCH_ENGINE = "127.0.0.1:8095";
        SEARCH_DOMAIN = cfg.domain;
        SEARCH_SECRET = "${state}/secret";
      };
      serviceConfig = sandbox // {
        ExecStart = "${pkgs.python3}/bin/python3 ${./search.py}";
        Restart = "on-failure";
        RestrictAddressFamilies = [ "AF_INET" ];
      };
    };

    # Caddy on :8080, sandboxed like the rest and without the packaged unit's capabilities.
    systemd.services.caddy.serviceConfig = {
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = lib.mkForce "strict";
      ProtectHome = true;
      CapabilityBoundingSet = [ "" ];
      LockPersonality = true;
    };
    # Every request is signed in first; searx's own proxies are reached only through it.
    services.caddy = {
      enable = true;
      virtualHosts."http://:8080".extraConfig = ''
        ${import ../headers.nix}
        handle /oauth2/* {
          reverse_proxy 127.0.0.1:4180
        }
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
            @proxied path /image_proxy /favicon_proxy
            reverse_proxy @proxied 127.0.0.1:8095
            reverse_proxy 127.0.0.1:8096
          }
        }
      '';
    };

    # It looks the provider up at start, so names must resolve; it keeps trying.
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
      upstream = [ "http://127.0.0.1:8096" ];
      email.domains = [ "*" ];
      reverseProxy = true;
      trustedProxyIP = [ "127.0.0.1" ];
      scope = "openid email profile";
      cookie = { name = "_search_login"; secure = true; expire = "720h0m0s"; };
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
