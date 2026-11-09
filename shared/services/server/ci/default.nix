# CI for any git repository with nixbot: evaluation in this container's own store, every
# build sent to the builder the settings page sets for its system, results pushed
# to attic. Its secrets are entered on that page and kept in /var/lib/ci/secrets.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.ci;
  secrets = "/var/lib/ci/secrets";
  # The repositories CI polls, as the page saves them; nixbot reads it at start.
  reposFile = "/var/lib/ci-builders/repos.json";
  # Pinned like a kernel: a known nixbot, changed only on purpose.
  nixbotSrc = builtins.fetchGit {
    url = "https://github.com/Mic92/nixbot";
    rev = "849c4fa2f8bd68968c4447316e41addcba520540";
    shallow = true;
  };
  packages = config.services.nixbot.packages;
  # A container may not mount a fresh /proc, so the eval sandbox binds its own;
  # the repositories it polls come from the page's list, not the build; and a
  # repository may keep its settings hidden, in .nixbot.toml.
  nixbot = (packages.python.pkgs.callPackage (nixbotSrc + "/packages/nixbot.nix") {
    inherit (packages) nix-eval-jobs;
  }).overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace nixbot/nix_eval.py --replace-fail '"--proc",' '"--ro-bind", "/proc",'
      substituteInPlace nixbot/repo_config.py --replace-fail \
        'CONFIG_FILENAMES = ("nixbot.toml",' 'CONFIG_FILENAMES = (".nixbot.toml", "nixbot.toml",'
      substituteInPlace nixbot/config.py --replace-fail \
        '        return cls.model_validate(data)' \
        '        repos_file = Path("${reposFile}")
              if repos_file.exists() and (repos := json.loads(repos_file.read_text())):
                  data["pull_based"] = {"repositories": repos, "poll_spread": 30}
              return cls.model_validate(data)'
    '';
  });
  # After every successful build: push it to the cache its repository names, and pin it.
  publish = pkgs.writers.writePython3 "ci-publish" { flakeIgnore = [ "E501" "W503" ]; } (builtins.readFile ./publish.py);
  interpolate = (import (nixbotSrc + "/nix/lib.nix")).interpolate;
  # The whole site, made like the cache UI; nixbot works underneath it.
  site = pkgs.writers.writePython3 "ci-ui" { flakeIgnore = [ "E501" "W503" ]; } (builtins.readFile ./ui.py);
in
{
  imports = [ (nixbotSrc + "/nixosModules/nixbot.nix") ];

  options.bresilla.services.ci = {
    domain = lib.mkOption { type = lib.types.str; };
    login = lib.mkOption {
      default = null;
      description = "Sign-in to the site through an OpenID Connect provider, by a login proxy.";
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          issuer = lib.mkOption { type = lib.types.str; };
          client = lib.mkOption { type = lib.types.str; };
          envFile = lib.mkOption { type = lib.types.str; description = "OAUTH2_PROXY_CLIENT_SECRET and _COOKIE_SECRET."; };
          adminClaim = lib.mkOption { type = lib.types.str; description = "Claim whose value \"admin\" lets a user run CI."; };
        };
      });
    };
    cache = lib.mkOption { type = lib.types.str; description = "cache.bresilla.com as reached from here: attic and its pins."; };
    proxy = lib.mkOption { type = lib.types.str; description = "Address of the proxy in front of it, trusted for the client's address."; };
    systems = lib.mkOption { type = lib.types.listOf lib.types.str; description = "Systems CI builds."; };
    seed = lib.mkOption {
      type = lib.types.attrs;
      description = "Builders and their systems before the builders page has saved any.";
    };
  };

  config = {
    system.stateVersion = "26.05";
    networking.firewall.allowedTCPPorts = [ 80 ];
    # The host's resolver listens on its own loopback, which this network can't reach.
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];

    # The caches every machine uses, so what is already built is never built again;
    # cache.bresilla.com's own ones straight from the cache container.
    nix.settings = let
      caches = builtins.attrValues (builtins.fromJSON (builtins.readFile ../../../caches.json));
      local = url: builtins.replaceStrings [ "https://cache.bresilla.com" ] [ cfg.cache ] url;
    in {
      extra-substituters = map (c: local c.url) caches;
      extra-trusted-public-keys = map (c: c.key) caches;
    };

    services.nixbot = {
      enable = true;
      inherit (cfg) domain;
      useHTTPS = true;
      # Reached only by the page, which lets id.bresilla.com's build admins act as this one.
      proxyAuthHeader = "X-Remote-User";
      admins = [ "proxy:build-admin" ];
      buildSystems = cfg.systems;
      evalWorkerCount = 4;
      evalMaxMemorySize = 3072;
      packages.nixbot = nixbot;
      # Caddy is in front, not the module's nginx.
      nginx.enable = false;
      postBuildSteps = [{
        name = "publish";
        command = [ "${publish}" ];
        environment = {
          CI_ATTR = interpolate "%(prop:attr)s";
          CI_SYSTEM = interpolate "%(prop:system)s";
          CI_OUT = interpolate "%(prop:out_path)s";
          CI_PROJECT = interpolate "%(prop:project)s";
          CI_BRANCH = interpolate "%(prop:branch)s";
          CI_REVISION = interpolate "%(prop:revision)s";
          CI_DEFAULT_BRANCH = interpolate "%(prop:default_branch)s";
          CI_ATTIC = "${pkgs.attic-client}/bin/attic";
          CI_GIT = "${pkgs.git}/bin/git";
          CI_CACHE = cfg.cache;
          CI_REPOS = reposFile;
        };
      }];
    };
    systemd.services.nixbot.serviceConfig.LoadCredential = [
      "attic-token:${secrets}/attic-token"
      "pin-token:${secrets}/pin-token"
    ];
    # Saving secrets or repositories on the page restarts nixbot with them.
    systemd.paths.nixbot-secrets = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = [ "${secrets}/saved" reposFile ];
    };
    systemd.services.nixbot-secrets = {
      serviceConfig.Type = "oneshot";
      script = "systemctl restart nixbot.service";
    };

    # The site is this container's own page; nixbot is reached only by the page,
    # over its socket, which the module only keeps with nginx.
    users.users.ci-builders.extraGroups = [ "nixbot" ];
    systemd.sockets.nixbot.socketConfig.ListenStream = lib.mkForce "/run/nixbot/web.sock";
    # Its start waits until it answers, there too.
    systemd.services.nixbot.serviceConfig.ExecStartPost = lib.mkForce (pkgs.writeShellScript "nixbot-health" ''
      for _ in $(seq 60); do
        ${pkgs.curl}/bin/curl -fsS --max-time 5 --unix-socket /run/nixbot/web.sock http://localhost/health >/dev/null && exit 0
        sleep 1
      done
      echo "nixbot did not become healthy" >&2
      exit 1
    '');

    services.caddy = {
      enable = true;
      # The tunnel says who the visitor is and that they used https.
      globalConfig = ''
        servers {
          trusted_proxies static ${cfg.proxy}/32
        }
      '';
      # The site is open to everyone. Each request first asks the login proxy whether
      # someone is signed in; if so, their name and role go along, and nobody can
      # send those headers themselves. Signed out, the page shows itself read-only.
      virtualHosts."http://:80".extraConfig = let
        # Signed out, the empty handle_response lets the request go on without a name.
        who = lib.optionalString (cfg.login != null) ''
          forward_auth 127.0.0.1:4180 {
            uri /oauth2/auth
            copy_headers X-Auth-Request-Preferred-Username>X-Forwarded-Preferred-Username X-Auth-Request-Groups>X-Forwarded-Groups
            handle_response {
            }
          }
        '';
      in ''
        ${import ../headers.nix}
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
            ${who}
            # Build logs stream live, so nothing is held back.
            reverse_proxy 127.0.0.1:8091 {
              flush_interval -1
            }
          }
        }
      '';
    };

    # It looks the provider up at start, so names must resolve; it keeps trying.
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
      upstream = [ "http://127.0.0.1:8091" ];
      email.domains = [ "*" ];
      reverseProxy = true;
      trustedProxyIP = [ "127.0.0.1" ];
      scope = "openid email profile";
      cookie = { name = "_build_login"; secure = true; expire = "336h0m0s"; };
      approvalPrompt = "auto";
      passBasicAuth = false;
      extraConfig = {
        # Straight to id.bresilla.com, no page of its own in between.
        skip-provider-button = true;
        # Signing out ends the session on the provider too, on its own domain.
        whitelist-domain = builtins.elemAt (lib.splitString "/" cfg.login.issuer) 2;
        code-challenge-method = "S256";
        oidc-groups-claim = cfg.login.adminClaim;
        # Answers "who is this?" for the site, which is open to everyone.
        set-xauthrequest = true;
        insecure-oidc-allow-unverified-email = true;
      };
    };

    # The builders page: which machine builds which system, written to the
    # machines file the Nix daemon reads for every remote build.
    users.users.ci-builders = { isSystemUser = true; group = "ci-builders"; home = "/var/lib/ci-builders"; };
    users.groups.ci-builders = { };
    # The token files exist from the start, empty until set, so nixbot always starts.
    systemd.tmpfiles.rules = [
      "d /var/lib/ci 0770 root ci-builders - -"
      "d ${secrets} 0700 ci-builders ci-builders - -"
      "f ${secrets}/attic-token 0600 ci-builders ci-builders - -"
      "f ${secrets}/pin-token 0600 ci-builders ci-builders - -"
      # The page's own accounts, from before id.bresilla.com.
      "r /var/lib/ci-builders/users.json - - - - -"
    ];
    # The builders page checks machines with its own copy of the key: ssh refuses
    # a key anyone besides its owner may read.
    systemd.services.builder-key.serviceConfig.ExecStartPost = [
      "${pkgs.coreutils}/bin/chmod 0600 /var/lib/ci/builder_ed25519"
      "${pkgs.coreutils}/bin/install -D -m 0600 -o ci-builders -g ci-builders /var/lib/ci/builder_ed25519 /var/lib/ci-builders/builder_ed25519"
    ];
    systemd.services.ci-builders = {
      description = "build.bresilla.com";
      wantedBy = [ "multi-user.target" ];
      after = [ "builder-key.service" ];
      path = [ config.nix.package pkgs.openssh pkgs.coreutils ];
      environment = {
        CI_SEED = builtins.toJSON cfg.seed;
        CI_SYSTEMS = lib.concatStringsSep " " cfg.systems;
        CI_LOGO = "${../../../../configs/assets/bresilla.svg}";
        CI_STYLE = "${./ui.css}";
        CI_DOMAIN = cfg.domain;
      };
      serviceConfig = {
        ExecStart = site;
        SupplementaryGroups = [ "nixbot" ];
        User = "ci-builders";
        StateDirectory = "ci-builders";
        ReadWritePaths = [ "/var/lib/ci" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        CapabilityBoundingSet = "";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
        Restart = "on-failure";
      };
    };
  };
}
