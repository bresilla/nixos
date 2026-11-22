# dump: nest's snapshots pushed to targets added and removed on status.bresilla.com.
# hive keeps the list (the hub); nest's manager reaches every target over SSH, formats
# the disk picked there, and pushes each night. A target machine only needs the `dump`
# user below (or the same by hand on a machine that is not NixOS).
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.dump;
  inherit (import ./source.nix) source hub managerKey;
  home = "/var/lib/dump/manager";
  isSource = config.networking.hostName == source.host;
  manager = pkgs.writeShellScriptBin "dump-manager" ''
    exec ${pkgs.python3}/bin/python3 ${./manager.py} "$@"
  '';
  env = { DUMP_HUB = "http://hive.link:${toString hub.port}"; DUMP_HOME = home; };
  path = with pkgs; [ btrbk btrfs-progs util-linux coreutils openssh restic rclone mbuffer ];
  # What nest may run on a target, as root; nothing else.
  allowed = [ "btrfs" "readlink" "mkdir" "mount" "umount" "pvcreate" "vgcreate" "lvcreate" "lvremove" "vgremove" "mkfs.btrfs" "wipefs" ];
in {
  options.bresilla.dump = {
    target.enable = lib.mkEnableOption "letting nest push dump copies to this machine over SSH";
    hub.enable = lib.mkEnableOption "dump's hub, on hive";
  };

  config = lib.mkMerge [
    # --- nest: the manager -------------------------------------------------------------
    (lib.mkIf isSource {
      environment.systemPackages = [ manager ];
      systemd.services.dump-manager = {
        description = "dump: follow hive's target list, set targets up, report";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = env;
        inherit path;
        serviceConfig = { Type = "oneshot"; ExecStart = "${lib.getExe manager} sync"; TimeoutStartSec = "15min"; };
      };
      systemd.timers.dump-manager = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "5min"; };
      };
      # Nightly, once the first snapshot after 06:00 local (05:30 UTC in winter) exists.
      systemd.services.dump-push = {
        description = "dump: push nest's newest snapshots to every disk target";
        environment = env;
        inherit path;
        serviceConfig = { Type = "oneshot"; ExecStart = "${lib.getExe manager} push"; Nice = 10; IOSchedulingClass = "idle"; };
      };
      systemd.timers.dump-push = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnCalendar = "*-*-* 06:00:00 UTC"; Persistent = true; };
      };
      systemd.services.dump-restic = {
        description = "dump: back nest's newest snapshots up to every restic target";
        environment = env;
        inherit path;
        serviceConfig = { Type = "oneshot"; ExecStart = "${lib.getExe manager} restic"; Nice = 10; IOSchedulingClass = "idle"; };
      };
      systemd.timers.dump-restic = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnCalendar = "*-*-* 05:30:00 UTC"; Persistent = true; };
      };
      systemd.tmpfiles.rules = [ "d /var/lib/dump 0755 root root -" "d ${home} 0700 root root -" ];
      # btrbk's own SSH also trusts the targets' host keys the manager first met.
      programs.ssh.extraConfig = ''
        Host *
          UserKnownHostsFile ~/.ssh/known_hosts ${home}/known_hosts
      '';
    })

    # --- a machine nest may push to --------------------------------------------------------
    (lib.mkIf cfg.target.enable {
      environment.systemPackages = with pkgs; [ btrfs-progs lvm2 ];
      users.groups.dump = { };
      users.users.dump = {
        isSystemUser = true;
        group = "dump";
        shell = "${pkgs.bash}/bin/bash";
        home = "/var/empty";
        openssh.authorizedKeys.keys = lib.optional (managerKey != "") managerKey;
      };
      security.sudo.extraRules = [{
        users = [ "dump" ];
        # mount and umount are found first as NixOS's setuid wrappers, so those paths too.
        commands = map (c: { command = c; options = [ "NOPASSWD" ]; })
          (map (c: "/run/current-system/sw/bin/${c}") allowed ++ [ "/run/wrappers/bin/mount" "/run/wrappers/bin/umount" ]);
      }];
    })

    # --- hive: the hub, on the cable to nest only ------------------------------------------
    (lib.mkIf cfg.hub.enable {
      systemd.services.dump-hub = {
        description = "dump's hub: the target list, and nest's reports";
        wantedBy = [ "multi-user.target" ];
        environment = {
          DUMP_STATE = "/var/lib/dump";
          DUMP_REPORTS = "/var/lib/status";
          DUMP_AGENTS = builtins.toJSON { ${source.host} = [ hub.nest ]; };
          DUMP_SOURCE = builtins.toJSON source;
          DUMP_LISTEN = "${hub.link}:${toString hub.port}";
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./hub.py}";
          Restart = "always";
          RestartSec = 5;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/dump" "/var/lib/status" ];
          ProtectHome = true;
          NoNewPrivileges = true;
        };
      };
      networking.firewall.extraInputRules = "ip saddr ${hub.nest} tcp dport ${toString hub.port} accept";
    })
  ];
}
