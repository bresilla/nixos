# CI for gitea repos with nixbot: evaluation in this container's own store, every
# build sent to the builder the builders page sets for its system, results pushed
# to attic. Secrets live only in /var/lib/ci/secrets, put there by hive's ci-secrets.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.ci;
  secrets = "/var/lib/ci/secrets";
  # Pinned like a kernel: a known nixbot, changed only on purpose.
  nixbotSrc = builtins.fetchGit {
    url = "https://github.com/Mic92/nixbot";
    rev = "849c4fa2f8bd68968c4447316e41addcba520540";
    shallow = true;
  };
  packages = config.services.nixbot.packages;
  # A container may not mount a fresh /proc, so the eval sandbox binds its own.
  nixbot = (packages.python.pkgs.callPackage (nixbotSrc + "/packages/nixbot.nix") {
    inherit (packages) nix-eval-jobs;
  }).overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace nixbot/nix_eval.py --replace-fail '"--proc",' '"--ro-bind", "/proc",'
    '';
  });
  # Logs in to the cache with the token file, then pushes the paths on stdin.
  atticPush = pkgs.writeShellScript "ci-attic-push" ''
    export HOME=/var/lib/nixbot
    ${pkgs.attic-client}/bin/attic login ci ${cfg.cache} "$(< "$CREDENTIALS_DIRECTORY/attic-token")" >/dev/null
    exec ${pkgs.attic-client}/bin/attic push ci:${cfg.cacheName} --stdin
  '';
  theme = pkgs.runCommand "ci-theme" { } ''
    mkdir -p $out
    cp ${./theme.css} $out/theme.css
    cp ${./theme.js} $out/theme.js
    cp ${../gitea/public/assets/img/logo.svg} $out/logo.svg
  '';
  builders = pkgs.writers.writePython3 "ci-builders" { flakeIgnore = [ "E501" "W503" ]; } (builtins.readFile ./builders.py);
in
{
  imports = [ (nixbotSrc + "/nixosModules/nixbot.nix") ];

  options.bresilla.services.ci = {
    domain = lib.mkOption { type = lib.types.str; };
    gitea = lib.mkOption { type = lib.types.str; description = "Gitea's public URL."; };
    oauthId = lib.mkOption { type = lib.types.str; description = "Client ID of gitea's nixbot OAuth app (public)."; };
    admins = lib.mkOption { type = lib.types.listOf lib.types.str; description = "Gitea user names that run CI."; };
    cache = lib.mkOption { type = lib.types.str; description = "Attic server the results go to."; };
    cacheName = lib.mkOption { type = lib.types.str; default = "bresilla"; };
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

    services.nixbot = {
      enable = true;
      inherit (cfg) domain;
      useHTTPS = true;
      admins = map (u: "gitea:${u}") cfg.admins;
      buildSystems = cfg.systems;
      evalWorkerCount = 4;
      evalMaxMemorySize = 3072;
      packages.nixbot = nixbot;
      gitea = {
        enable = true;
        instanceUrl = cfg.gitea;
        tokenFile = "${secrets}/gitea-token";
        inherit (cfg) oauthId;
        oauthSecretFile = "${secrets}/gitea-oauth-secret";
      };
      uploaders = [{
        name = "attic";
        command = [ "${atticPush}" ];
        pathsVia = "stdin";
      }];
    };
    systemd.services.nixbot.serviceConfig.LoadCredential = [ "attic-token:${secrets}/attic-token" ];

    # The theme gitea and the cache wear, added to every nixbot page, and the
    # builders page beside it.
    services.nginx.virtualHosts.${cfg.domain}.locations = {
      "/".extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header Accept-Encoding "";
        sub_filter '</head>' '<link rel="stylesheet" href="/_bresilla/theme.css"><script src="/_bresilla/theme.js"></script></head>';
        sub_filter_once on;
      '';
      "/_bresilla/".alias = "${theme}/";
      "/builders" = {
        proxyPass = "http://127.0.0.1:8091";
        extraConfig = "proxy_set_header Host $host;";
      };
    };

    # The builders page: which machine builds which system, written to the
    # machines file the Nix daemon reads for every remote build.
    users.users.ci-builders = { isSystemUser = true; group = "ci-builders"; home = "/var/lib/ci-builders"; };
    users.groups.ci-builders = { };
    systemd.tmpfiles.rules = [ "d /var/lib/ci 0770 root ci-builders - -" "d ${secrets} 0700 root root - -" ];
    systemd.services.builder-key.serviceConfig.ExecStartPost =
      "${pkgs.coreutils}/bin/chgrp ci-builders /var/lib/ci/builder_ed25519";
    systemd.services.ci-builders = {
      description = "Builders page";
      wantedBy = [ "multi-user.target" ];
      after = [ "builder-key.service" ];
      path = [ config.nix.package pkgs.openssh pkgs.coreutils ];
      environment = {
        CI_SEED = builtins.toJSON cfg.seed;
        CI_SYSTEMS = lib.concatStringsSep " " cfg.systems;
        CI_THEME = "/_bresilla";
      };
      serviceConfig = {
        ExecStart = builders;
        User = "ci-builders";
        StateDirectory = "ci-builders";
        LoadCredential = [ "builders-token:${secrets}/builders-token" ];
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
