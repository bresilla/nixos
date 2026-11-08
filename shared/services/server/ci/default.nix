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
  # and the repositories it polls come from the page's list, not the build.
  nixbot = (packages.python.pkgs.callPackage (nixbotSrc + "/packages/nixbot.nix") {
    inherit (packages) nix-eval-jobs;
  }).overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace nixbot/nix_eval.py --replace-fail '"--proc",' '"--ro-bind", "/proc",'
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
    admins = lib.mkOption { type = lib.types.listOf lib.types.str; description = "Accounts of this site that may run CI."; };
    cache = lib.mkOption { type = lib.types.str; description = "cache.bresilla.com as reached from here: attic and its pins."; };
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
      # Signed in on this site, as on the cache UI; the page passes the name on.
      proxyAuthHeader = "X-Remote-User";
      admins = map (u: "proxy:${u}") cfg.admins;
      buildSystems = cfg.systems;
      evalWorkerCount = 4;
      evalMaxMemorySize = 3072;
      packages.nixbot = nixbot;
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
    # over its socket.
    users.users.ci-builders.extraGroups = [ "nixbot" ];
    services.nginx.virtualHosts.${cfg.domain}.locations = {
      "/" = {
        proxyPass = lib.mkForce (if cfg.login == null then "http://127.0.0.1:8091" else "http://127.0.0.1:4180");
        extraConfig = lib.mkForce "proxy_set_header Host $host;";
      };
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
      scope = "openid email profile";
      cookie = { name = "_build_login"; secure = true; expire = "336h0m0s"; };
      approvalPrompt = "auto";
      passBasicAuth = false;
      extraConfig = {
        # Straight to id.bresilla.com, no page of its own in between.
        skip-provider-button = true;
        code-challenge-method = "S256";
        oidc-groups-claim = cfg.login.adminClaim;
        pass-user-headers = true;
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
    ];
    # The builders page checks machines with its own copy of the key: ssh refuses
    # a key anyone besides its owner may read.
    systemd.services.builder-key.serviceConfig.ExecStartPost = [
      "${pkgs.coreutils}/bin/chmod 0600 /var/lib/ci/builder_ed25519"
      "${pkgs.coreutils}/bin/install -D -m 0600 -o ci-builders -g ci-builders /var/lib/ci/builder_ed25519 /var/lib/ci-builders/builder_ed25519"
    ];
    # Accounts, as `sudo cache-ui-user` on the cache: `sudo ci-user add|remove|list` on hive.
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "ci-user" "exec ${site} user \"$@\"")
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
