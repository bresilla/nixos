{ murosPackage, murosModule, cacheDefinitions, responseHeaders }:
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.ci;
  localCache = url: builtins.replaceStrings [ "https://cache.bresilla.com" ] [ cfg.cache ] url;
in {
  imports = [ murosModule ];
  options.bresilla.services.ci = {
    domain = lib.mkOption { type = lib.types.str; };
    cache = lib.mkOption { type = lib.types.str; };
    proxy = lib.mkOption { type = lib.types.str; };
    login = lib.mkOption {
      default = null;
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          issuer = lib.mkOption { type = lib.types.str; };
          client = lib.mkOption { type = lib.types.str; };
          envFile = lib.mkOption { type = lib.types.str; };
          adminClaim = lib.mkOption { type = lib.types.str; };
        };
      });
    };
  };
  config = {
    system.stateVersion = "26.05";
    networking.firewall.allowedTCPPorts = [ 80 ];
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
    nix.settings = {
      extra-substituters = map (cache: localCache cache.url) cacheDefinitions;
      extra-trusted-public-keys = map (cache: cache.key) cacheDefinitions;
    };
    environment.systemPackages = [ murosPackage ];
    services.murosd = {
      enable = true;
      package = murosPackage;
      credentials = {
        builder-key = "/var/lib/ci/builder_ed25519";
        attic-token = "/var/lib/ci/secrets/attic-token";
        pin-token = "/var/lib/ci/secrets/pin-token";
        token-secret = "/var/lib/murosd-secrets/token-secret";
      };
      settings = {
        listen = "127.0.0.1:8090";
        api-endpoint = "https://${cfg.domain}/";
        allowed-hosts = [ cfg.domain "localhost" "127.0.0.1" ];
        eval = {
          workers = 4;
          max-memory-size = 3072;
          memory-limit = 12884901888;
          sandbox = true;
          procfs = "parent-read-only";
          timeout = "1h";
        };
        build = {
          max-concurrent = 8;
          ssh-key-file = "/run/credentials/murosd.service/builder-key";
          ssh-key-runtime-dir = "/run/murosd";
        };
        publish = {
          attic-endpoint = cfg.cache;
          direct-endpoint = cfg.cache;
          default-cache = "packages";
          attic-token-file = "/run/credentials/murosd.service/attic-token";
          pin-token-file = "/run/credentials/murosd.service/pin-token";
        };
        auth.proxy = {
          header = "X-Forwarded-Preferred-Username";
          groups-header = "X-Forwarded-Groups";
          trusted-proxies = [ "127.0.0.1" "::1" ];
          admin-group = "admin";
        };
        token.hs256-secret-file = "/run/credentials/murosd.service/token-secret";
      };
    };
    systemd.services.murosd = {
      after = [ "builder-key.service" ];
      requires = [ "builder-key.service" ];
    };
    services.caddy = {
      enable = true;
      globalConfig = ''
        servers {
          trusted_proxies static ${cfg.proxy}/32
        }
      '';
      virtualHosts."http://:80".extraConfig = ''
        ${responseHeaders}
        ${lib.optionalString (cfg.login != null) ''
          handle /oauth2/* {
            reverse_proxy 127.0.0.1:4180
          }
        ''}
        handle {
          route {
            request_header -X-Forwarded-User
            request_header -X-Forwarded-Preferred-Username
            request_header -X-Forwarded-Groups
            request_header -X-Forwarded-Email
            ${lib.optionalString (cfg.login != null) ''
              forward_auth 127.0.0.1:4180 {
                uri /oauth2/auth
                copy_headers X-Auth-Request-Preferred-Username>X-Forwarded-Preferred-Username X-Auth-Request-Groups>X-Forwarded-Groups
                handle_response {
                }
              }
            ''}
            reverse_proxy 127.0.0.1:8090 {
              flush_interval -1
            }
          }
        }
      '';
    };
    systemd.services.oauth2-proxy = lib.mkIf (cfg.login != null) {
      after = [ "network-online.target" "resolvconf.service" ];
      wants = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      serviceConfig.RestartSec = 10;
    };
    services.oauth2-proxy = lib.mkIf (cfg.login != null) {
      enable = true;
      provider = "oidc";
      clientID = cfg.login.client;
      keyFile = cfg.login.envFile;
      oidcIssuerUrl = cfg.login.issuer;
      redirectURL = "https://${cfg.domain}/oauth2/callback";
      httpAddress = "http://127.0.0.1:4180";
      upstream = [ "http://127.0.0.1:8090" ];
      email.domains = [ "*" ];
      reverseProxy = true;
      trustedProxyIP = [ "127.0.0.1" ];
      scope = "openid email profile";
      cookie = { name = "_build_login"; secure = true; expire = "336h0m0s"; };
      approvalPrompt = "auto";
      passBasicAuth = false;
      extraConfig = {
        skip-provider-button = true;
        whitelist-domain = builtins.elemAt (lib.splitString "/" cfg.login.issuer) 2;
        code-challenge-method = "S256";
        oidc-groups-claim = cfg.login.adminClaim;
        set-xauthrequest = true;
        insecure-oidc-allow-unverified-email = true;
      };
    };
  };
}
