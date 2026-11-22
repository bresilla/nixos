self: { config, lib, pkgs, ... }:
let
  cfg = config.services.murosd;
  format = pkgs.formats.toml { };
  configFile = format.generate "murosd.toml" cfg.settings;
  state = cfg.settings.state.path;
  roots = cfg.settings.build.gc-roots;
  localPostgres = cfg.database.createLocally;
  grace = cfg.settings.build.shutdown-grace or "0s";
  graceParts = builtins.match "([0-9]+)(s|m|min|h)" grace;
  graceSeconds = if graceParts == null then 0 else
    lib.toInt (builtins.elemAt graceParts 0) * { s = 1; m = 60; min = 60; h = 3600; }.${builtins.elemAt graceParts 1};
  health = pkgs.writeShellScript "murosd-health" ''
    exec ${pkgs.curl}/bin/curl --fail --silent --show-error \
      --retry 30 --retry-delay 1 --retry-connrefused \
      --header ${lib.escapeShellArg "Host: ${builtins.head cfg.settings.allowed-hosts}"} \
      ${lib.escapeShellArg cfg.healthCheckUrl}
  '';
in {
  options.services.murosd = {
    enable = lib.mkEnableOption "muros remote Nix builder";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.muros;
      description = "Package containing murosd, murosadm, and muros.";
    };
    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = "murosd TOML settings. Secret values must be file references.";
    };
    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime environment file outside the Nix store.";
    };
    credentials = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Credential names mapped to runtime source files for LoadCredential.";
    };
    mode = lib.mkOption {
      type = lib.types.enum [ "monolithic" ];
      default = "monolithic";
      description = "Daemon operating mode.";
    };
    database.createLocally = lib.mkEnableOption "a local PostgreSQL database with peer authentication";
    healthCheckUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${builtins.replaceStrings [ "[::]" "0.0.0.0" ] [ "[::1]" "127.0.0.1" ] cfg.settings.listen}/health";
      description = "Local health URL used by ExecStartPost.";
    };
    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "16G";
      description = "MemoryMax for murosd, including its evaluation cgroup; at least eval.memory-limit plus headroom.";
    };
    memoryHigh = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional MemoryHigh throttling threshold below memoryMax.";
    };
    tasksMax = lib.mkOption {
      type = lib.types.int;
      default = 8192;
      description = "TasksMax for murosd and its evaluator and Git subprocesses.";
    };
    secretsKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/murosd-secrets/key";
      description = "Runtime file with the 32-byte job secrets key, passed to murosd as the systemd credential secrets-key.";
    };
    stepPackages = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = { };
      example = lib.literalExpression ''{ aarch64-linux = muros.packages.aarch64-linux.muros-static; }'';
      description = "Packages providing bin/muros-step for CI workers of other native systems, built from the same muros.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.environmentFile == null || !lib.hasPrefix "/nix/store/" cfg.environmentFile;
        message = "murosd environmentFile must not be in the Nix store.";
      }
      {
        assertion = graceParts != null;
        message = "services.murosd.settings.build.shutdown-grace must be a whole number of s, m, min or h, so the module can give systemd a longer stop timeout.";
      }
      {
        assertion = lib.all (path: lib.hasPrefix "/" path && !lib.hasPrefix "/nix/store/" path) (builtins.attrValues cfg.credentials);
        message = "murosd credential source files must be absolute runtime paths outside the Nix store.";
      }
    ];
    services.murosd.settings = {
      listen = lib.mkDefault "[::]:8090";
      api-endpoint = lib.mkDefault "http://localhost:8090/";
      allowed-hosts = lib.mkDefault [ "localhost" "127.0.0.1" "[::1]" ];
      state.path = lib.mkDefault "/var/lib/murosd";
      build.gc-roots = lib.mkDefault "/nix/var/nix/gcroots/per-user/muros";
      build.probe-expression = lib.mkDefault (toString self.packages.${pkgs.stdenv.hostPlatform.system}.muros-probe);
      database.url = lib.mkDefault (if localPostgres then
        "postgresql:///murosd?host=/run/postgresql&user=murosd"
        else "sqlite://${state}/server.db?mode=rwc");
      jobs.muros-step = lib.mapAttrs (_: package: "${package}/bin/muros-step") cfg.stepPackages;
      secrets = lib.mkIf (cfg.secretsKeyFile != null) {
        key-file = "/run/credentials/murosd.service/secrets-key";
      };
    };
    services.murosd.credentials = lib.mkIf (cfg.secretsKeyFile != null) {
      secrets-key = cfg.secretsKeyFile;
    };
    users.groups.murosd = { };
    users.users.murosd = { isSystemUser = true; group = "murosd"; home = state; };
    nix.settings = {
      trusted-users = [ "murosd" ];
      max-jobs = lib.mkForce 0;
      builders = lib.mkForce "@${state}/machines";
      builders-use-substitutes = true;
      extra-substituters = cfg.settings.build.extra-substituters or [ ];
      experimental-features = [ "nix-command" "flakes" ];
    };
    systemd.tmpfiles.rules = [
      "d ${state} 0750 murosd murosd -"
      "f ${state}/machines 0640 murosd murosd -"
      "d ${roots} 0750 murosd murosd -"
    ];
    services.postgresql = lib.mkIf localPostgres {
      enable = true;
      ensureDatabases = [ "murosd" ];
      ensureUsers = [ { name = "murosd"; ensureDBOwnership = true; } ];
    };
    systemd.services.nix-daemon.environment.NIX_SSHOPTS = lib.mkDefault "-F /dev/null -oBatchMode=yes -oStrictHostKeyChecking=yes -oIdentitiesOnly=yes";
    systemd.services.murosd = {
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "nix-daemon.socket" ] ++ lib.optional localPostgres "postgresql.target";
      requires = lib.optional localPostgres "postgresql.target";
      path = with pkgs; [ nix nix-eval-jobs bubblewrap git openssh zstd bash ];
      environment.HOME = state;
      serviceConfig = {
        User = "murosd";
        Group = "murosd";
        DynamicUser = false;
        StateDirectory = "murosd";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "murosd";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = state;
        ExecStart = "${cfg.package}/bin/murosd -f ${configFile} --mode ${cfg.mode}";
        ExecStartPost = health;
        LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") cfg.credentials;
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = 5;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ state roots ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        CapabilityBoundingSet = "";
        UMask = "0077";
        Delegate = "memory";
        MemoryMax = cfg.memoryMax;
        MemoryHigh = lib.mkIf (cfg.memoryHigh != null) cfg.memoryHigh;
        TasksMax = cfg.tasksMax;
        ProtectKernelModules = true;
        ProtectClock = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "@mount" "unshare" "setns" "sethostname" ];
        SystemCallErrorNumber = "EPERM";
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
        TimeoutStopSec = graceSeconds + 30;
      };
    };
  };
}
