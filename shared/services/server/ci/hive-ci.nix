{ murosPackage, murosModule, cacheDefinitions, responseHeaders }:
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.ci;
  siteUi = import ../ui { inherit pkgs; };
  localCache = url: builtins.replaceStrings [ "https://cache.bresilla.com" ] [ cfg.cache ] url;
  frontend = pkgs.runCommand "muros-hive-ui" { } ''
    mkdir -p $out
    cp ${./hive-ui}/* $out/
  '';
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
          max-silent-time = "1h";
          timeout = "3h";
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
    systemd.tmpfiles.rules = [
      "d /var/lib/muros-ui 0700 murosd murosd -"
    ];
    systemd.services.muros-ui-permissions = {
      after = [ "builder-key.service" ];
      requires = [ "builder-key.service" ];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      script = ''
        test ! -L /var/lib/ci
        test ! -L /var/lib/ci/secrets
        install -d -m 0750 -o root -g murosd /var/lib/ci
        install -d -m 0700 -o murosd -g murosd /var/lib/ci/secrets
        for name in attic-token pin-token saved; do
          path=/var/lib/ci/secrets/$name
          test ! -L "$path"
          if test -f "$path"; then
            chown murosd:murosd "$path"
            chmod 0600 "$path"
          fi
        done
      '';
    };
    systemd.services.muros-ui = {
      wantedBy = [ "multi-user.target" ];
      wants = [ "murosd.service" ];
      after = [ "murosd.service" "muros-ui-permissions.service" ];
      requires = [ "muros-ui-permissions.service" ];
      path = with pkgs; [ nix openssh systemd ];
      environment = {
        CI_STYLE = "${frontend}/ui.css";
        PYTHONPATH = "${siteUi}";
        CI_ORIGIN = "https://${cfg.domain}";
        CI_SYSTEMS = "x86_64-linux aarch64-linux riscv64-linux";
        NIX_SSHOPTS = "-F /dev/null -oBatchMode=yes -oStrictHostKeyChecking=yes -oIdentitiesOnly=yes";
        PYTHONDONTWRITEBYTECODE = "1";
      };
      serviceConfig = {
        User = "murosd";
        Group = "murosd";
        ExecStart = "${pkgs.python3}/bin/python ${frontend}/ui.py";
        LoadCredential = [ "builder-key:/var/lib/ci/builder_ed25519" ];
        StateDirectory = "muros-ui";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/muros-ui";
        ReadWritePaths = [ "/var/lib/muros-ui" "/var/lib/ci/secrets" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 3;
      };
    };
    systemd.paths.muros-credentials = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = "/var/lib/ci/secrets/saved";
    };
    systemd.services.muros-credentials = {
      serviceConfig.Type = "oneshot";
      script = ''
        ${pkgs.systemd}/bin/systemctl restart murosd.service
      '';
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
            @backend path /api/* /auth/* /health /badge/*
            handle @backend {
              reverse_proxy 127.0.0.1:8090 {
                flush_interval -1
              }
            }
            handle {
              reverse_proxy 127.0.0.1:8091
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
