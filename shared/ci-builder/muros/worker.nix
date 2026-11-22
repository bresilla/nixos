{ config, lib, pkgs, ... }:
let
  cfg = config.services.muros-worker;
  session = import ./worker-session.nix {
    inherit pkgs;
    inherit (cfg) cores maxJobs;
    jobs = cfg.jobs.enable;
    jobMemoryMax = cfg.jobs.memoryMax;
    jobTasksMax = cfg.jobs.tasksMax;
    jobCpusMax = cfg.jobs.cpusMax;
    jobTimeoutMax = cfg.jobs.timeoutMax;
    jobFeatures = cfg.jobs.features;
  };
  scaled = units: text:
    let parts = builtins.match "([0-9]+)([a-zA-Z]*)" text;
    in lib.toInt (builtins.head parts) * units.${builtins.elemAt parts 1};
  caches = import ./worker-caches.nix {
    inherit pkgs;
    limitBytes = scaled { "" = 1; K = 1024; M = 1048576; G = 1073741824; T = 1099511627776; } cfg.jobs.cacheSize;
    maxAgeSeconds = scaled { s = 1; min = 60; h = 3600; d = 86400; w = 604800; } cfg.jobs.cacheAge;
  };
in {
  options.services.muros-worker = {
    enable = lib.mkEnableOption "the restricted Muros SSH worker session";
    acknowledgeTrustedAccess = lib.mkEnableOption "root-equivalent Nix trusted-user access for the dedicated account";
    user = lib.mkOption { type = lib.types.str; default = "muros-worker"; description = "Dedicated SSH worker account."; };
    authorizedKeys = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Explicitly authorized controller public keys."; };
    cores = lib.mkOption { type = lib.types.ints.between 1 1024; default = 1; description = "Compiler core hint per worker build session, not a CPU quota."; };
    maxJobs = lib.mkOption { type = lib.types.ints.between 1 1024; default = 1; description = "Nix build concurrency per worker session."; };
    emulatedSystems = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Explicitly approved Linux binfmt platforms; empty installs no emulation."; };
    jobs = {
      enable = lib.mkEnableOption "running repository CI jobs as throwaway systemd DynamicUser units";
      memoryMax = lib.mkOption { type = lib.types.str; default = "8G"; description = "MemoryMax for each job unit."; };
      tasksMax = lib.mkOption { type = lib.types.ints.positive; default = 4096; description = "TasksMax for each job unit."; };
      cpusMax = lib.mkOption { type = lib.types.ints.between 1 256; default = 256; description = "The most CPUs a job may request with resources.cpus."; };
      timeoutMax = lib.mkOption { type = lib.types.ints.between 1 86400; default = 86400; description = "The longest job timeout, in seconds, this worker accepts."; };
      features = lib.mkOption { type = lib.types.listOf (lib.types.enum [ "kvm" "userns" ]); default = [ ]; description = "Sandbox relaxations jobs may request with features; also add them as worker labels."; };
      cacheAge = lib.mkOption { type = lib.types.strMatching "[0-9]+(s|min|h|d|w)"; default = "14d"; description = "Job cache entries unused for this long are deleted."; };
      cacheSize = lib.mkOption { type = lib.types.strMatching "[0-9]+[KMGT]?"; default = "50G"; description = "Total size of job caches; the least recently used entries are deleted beyond it."; };
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = cfg.acknowledgeTrustedAccess; message = "Muros worker access is root-equivalent Nix trust; explicitly acknowledge it or use a dedicated builder VM."; }
      { assertion = cfg.authorizedKeys != []; message = "Muros workers require explicit controller public keys."; }
      { assertion = cfg.user != "root" && builtins.match "[a-z_][a-z0-9_-]*" cfg.user != null; message = "Muros requires a dedicated non-root Unix account name."; }
      { assertion = cfg.user != "nix-ssh" || !config.nix.sshServe.enable; message = "Disable nix.sshServe before reusing nix-ssh for the fixed Muros worker session, or choose a dedicated user."; }
    ];
    users.groups.${cfg.user} = {};
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      shell = pkgs.bashInteractive;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };
    nix.settings.trusted-users = [ cfg.user ];
    services.openssh.enable = true;
    services.openssh.extraConfig = ''
      Match User ${cfg.user}
        AllowAgentForwarding no
        AllowTcpForwarding no
        AllowStreamLocalForwarding no
        PermitTTY no
        PermitTunnel no
        X11Forwarding no
        ForceCommand ${session}/bin/muros-worker-session
      Match All
    '';
    boot.binfmt.emulatedSystems = cfg.emulatedSystems;
    security.polkit.enable = lib.mkIf cfg.jobs.enable true;
    systemd.tmpfiles.rules = lib.mkIf cfg.jobs.enable [ "d /var/cache/private 0700 root root -" "d /var/cache/private/muros 0755 root root -" ];
    systemd.services.muros-worker-caches = lib.mkIf cfg.jobs.enable {
      description = "Evict old and least recently used Muros job caches";
      serviceConfig = { Type = "oneshot"; ExecStart = "${caches}/bin/muros-worker-caches"; StateDirectory = "muros-worker-caches"; StateDirectoryMode = "0755"; };
    };
    systemd.timers.muros-worker-caches = lib.mkIf cfg.jobs.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "10min"; };
    };
    security.polkit.extraConfig = lib.mkIf cfg.jobs.enable ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" && subject.user == "${cfg.user}") {
          var unit = action.lookup("unit");
          if (unit && unit.indexOf("muros-job-") == 0) {
            return polkit.Result.YES;
          }
        }
      });
    '';
  };
}
