# dump: one machine's btrbk snapshots pushed to targets added and removed on the status
# page. The hub keeps the list; the manager reaches every target over SSH, formats the
# disk picked there and pushes each night; a target only runs the `dump` user below.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.dump;
  home = "/var/lib/dump/manager";
  code = ./.;
  python = "${pkgs.python3}/bin/python3";
  manager = pkgs.writeShellScriptBin "dump-manager" ''
    exec ${python} ${code}/manager.py "$@"
  '';
  managerEnv = {
    DUMP_HUB = cfg.manager.hub;
    DUMP_HOME = home;
    DUMP_SOURCE = builtins.toJSON { inherit (cfg.manager) volume snapshotDir shares; };
  };
  managerPath = with pkgs; [ btrbk btrfs-progs util-linux coreutils openssh restic rclone mbuffer ];
  oneshot = command: {
    environment = managerEnv // { TZ = "UTC"; };
    path = managerPath;
    serviceConfig = { Type = "oneshot"; ExecStart = "${lib.getExe manager} ${command}"; Nice = 10; IOSchedulingClass = "idle"; };
  };

  # What the manager may do on a target as root: these verbs, and btrbk's own filtered commands.
  helper = pkgs.writeShellApplication {
    name = "dump-target";
    runtimeInputs = with pkgs; [ util-linux lvm2 btrfs-progs coreutils gnugrep gawk findutils ];
    text = builtins.readFile ./target.sh;
  };
  sw = "/run/current-system/sw/bin";
  login = pkgs.writeShellScript "dump-login" ''
    case "''${SSH_ORIGINAL_COMMAND:-}" in
      "dump-target "*)
        read -r -a args <<<"$SSH_ORIGINAL_COMMAND"
        exec /run/wrappers/bin/sudo -n ${lib.getExe helper} "''${args[@]:1}" ;;
      *)
        exec ${pkgs.btrbk}/share/btrbk/scripts/ssh_filter_btrbk.sh --sudo --target --delete --info --restrict-path /mnt/dump ;;
    esac
  '';
in {
  options.bresilla.dump = {
    manager = {
      enable = lib.mkEnableOption "dump's manager, pushing this machine's snapshots to every target";
      hub = lib.mkOption { type = lib.types.str; description = "The hub's URL."; };
      volume = lib.mkOption { type = lib.types.str; description = "The btrfs top where the snapshots are."; };
      snapshotDir = lib.mkOption { type = lib.types.str; default = ".snapshots"; };
      shares = lib.mkOption { type = lib.types.listOf lib.types.str; description = "The subvolumes every target gets."; };
      keep = {
        to = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Directory the encrypted copy of the manager's own state goes to."; };
        recipients = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      };
    };
    hub = {
      enable = lib.mkEnableOption "dump's hub, keeping the target list";
      address = lib.mkOption { type = lib.types.str; description = "Address the hub listens on."; };
      port = lib.mkOption { type = lib.types.port; default = 9103; };
      manager = lib.mkOption { type = lib.types.str; description = "The only address the manager connects from."; };
    };
    target = {
      enable = lib.mkEnableOption "letting the dump manager push copies to this machine";
      managerKey = lib.mkOption { type = lib.types.str; description = "The manager's SSH public key."; };
      managerFrom = lib.mkOption { type = lib.types.listOf lib.types.str; description = "Addresses the manager connects from."; };
    };
  };

  config = lib.mkMerge [
    # --- the manager ---------------------------------------------------------------------
    (lib.mkIf cfg.manager.enable {
      environment.systemPackages = [ manager ];
      systemd.services.dump-manager = lib.recursiveUpdate (oneshot "sync") {
        description = "dump: follow the hub's target list, set targets up, report";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = { TimeoutStartSec = "15min"; Nice = 0; IOSchedulingClass = "best-effort"; };
      };
      systemd.timers.dump-manager = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "5min"; };
      };
      systemd.services.dump-push = oneshot "push" // { description = "dump: push the newest snapshots to every disk target"; };
      systemd.timers.dump-push = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnCalendar = "*-*-* 05:40:00 UTC"; Persistent = true; };
      };
      systemd.services.dump-restic = oneshot "restic" // { description = "dump: back the newest snapshots up to every restic target"; };
      systemd.timers.dump-restic = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnCalendar = "*-*-* 05:50:00 UTC"; Persistent = true; };
      };
      systemd.tmpfiles.rules = [ "d /var/lib/dump 0755 root root -" "d ${home} 0700 root root -" ];
      # The manager's key, restic passwords and rclone login, encrypted, where snapshots and
      # targets carry them: without them the restic copies cannot be read.
      systemd.services.dump-keep = lib.mkIf (cfg.manager.keep.to != null) {
        description = "dump: encrypted copy of the manager's own state";
        path = with pkgs; [ age age-plugin-yubikey gnutar coreutils diffutils ];
        serviceConfig = { Type = "oneshot"; UMask = "0077"; };
        script = ''
          cd /var/lib/dump
          set -- manager
          [ -e rclone.conf ] && set -- "$@" rclone.conf
          sum=$(tar -c --sort=name --mtime=@0 --owner=0 --group=0 --exclude='*.new' "$@" | sha256sum)
          [ "$sum" = "$(cat ${home}/kept.sum 2>/dev/null)" ] && [ -e ${cfg.manager.keep.to}/dump.tar.age ] && exit 0
          install -d -m 0700 ${cfg.manager.keep.to}
          tar -c --exclude='*.new' "$@" | age ${lib.concatMapStringsSep " " (r: "-r ${lib.escapeShellArg r}") cfg.manager.keep.recipients} -o ${cfg.manager.keep.to}/dump.tar.age.new
          mv ${cfg.manager.keep.to}/dump.tar.age.new ${cfg.manager.keep.to}/dump.tar.age
          echo "$sum" > ${home}/kept.sum
        '';
      };
      systemd.timers.dump-keep = lib.mkIf (cfg.manager.keep.to != null) {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnCalendar = "hourly"; Persistent = true; };
      };
      # The targets' host keys, for btrbk's SSH too; the manager writes the file.
      programs.ssh.extraConfig = ''
        Match all
        Include ${home}/ssh_config
      '';
    })

    # --- a target ------------------------------------------------------------------------
    (lib.mkIf cfg.target.enable {
      environment.systemPackages = with pkgs; [ btrfs-progs lvm2 helper ];
      users.groups.dump = { };
      users.users.dump = {
        isSystemUser = true;
        group = "dump";
        shell = "${pkgs.bash}/bin/bash";
        home = "/var/empty";
        openssh.authorizedKeys.keys = [
          ''restrict,command="${login}",from="${lib.concatStringsSep "," cfg.target.managerFrom}" ${cfg.target.managerKey}''
        ];
      };
      security.sudo.extraRules = [{
        users = [ "dump" ];
        commands = map (c: { command = c; options = [ "NOPASSWD" ]; })
          [ (lib.getExe helper) "${sw}/btrfs" "${sw}/readlink" "${sw}/mkdir" ];
      }];
    })

    # --- the hub -------------------------------------------------------------------------
    (lib.mkIf cfg.hub.enable {
      systemd.services.dump-hub = {
        description = "dump's hub: the target list, and the manager's reports";
        wantedBy = [ "multi-user.target" ];
        environment = {
          DUMP_STATE = "/var/lib/dump";
          DUMP_REPORTS = "/var/lib/status";
          DUMP_MANAGER = cfg.hub.manager;
          DUMP_LISTEN = "${cfg.hub.address}:${toString cfg.hub.port}";
        };
        serviceConfig = {
          ExecStart = "${python} ${code}/hub.py";
          Restart = "always";
          RestartSec = 5;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/dump" "/var/lib/status" ];
          ProtectHome = true;
          NoNewPrivileges = true;
        };
      };
      networking.firewall.extraInputRules = "ip saddr ${cfg.hub.manager} tcp dport ${toString cfg.hub.port} accept";
    })
  ];
}
