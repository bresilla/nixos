# dump: every machine reads targets.nix and takes its own part. The machine a btrbk
# target names mounts its disk and pulls nest's snapshots each night; nest lets each
# such machine only read its snapshots, and runs one restic job per restic target.
# A machine that is neither does nothing here.
{ config, lib, pkgs, ... }:
let
  inherit (import ./targets.nix) source targets;
  me = config.networking.hostName;
  btrbkTargets = lib.filterAttrs (_: t: t.kind == "btrbk") targets;
  resticTargets = lib.filterAttrs (_: t: t.kind == "restic") targets;
  mine = lib.filterAttrs (_: t: t.host == me) btrbkTargets;
  mount = name: "/mnt/dump/${name}";
  key = "/var/lib/btrbk/.ssh/dump_ed25519";
  reports = "/run/dump-status";
  collect = pkgs.writeShellApplication {
    name = "status-collect";
    runtimeInputs = with pkgs; [ systemd jq coreutils util-linux openssl findutils gawk gnused gnugrep btrfs-progs smartmontools sqlite curl ];
    text = builtins.readFile ../status/collect.sh;
  };
  # "14d 8w 12m" in btrbk's words, as restic's --keep options.
  keepFlags = keep: map (k: let
    n = lib.substring 0 (lib.stringLength k - 1) k;
    unit = lib.substring (lib.stringLength k - 1) 1 k;
  in "--keep-${{ h = "hourly"; d = "daily"; w = "weekly"; m = "monthly"; y = "yearly"; }.${unit}} ${n}") (lib.splitString " " keep);
  restic = "/run/dump-restic";
in {
  config = lib.mkMerge [
    # --- a machine holding a btrbk target ------------------------------------------------
    (lib.mkIf (mine != { }) {
      fileSystems = lib.mapAttrs' (name: _: lib.nameValuePair (mount name) {
        device = "/dev/dump/${name}";
        fsType = "btrfs";
        options = [ "noatime" "compress=zstd:3" "nofail" "x-systemd.device-timeout=10s" ];
      }) mine;

      programs.ssh.knownHosts.dump-source = { hostNames = [ source.address ]; publicKey = source.hostKey; };

      # Nightly, nest's newest snapshot of every share, sent only as what changed since the
      # last one; nest's snapshots are never created or deleted from here.
      services.btrbk.instances = lib.mapAttrs' (name: t: lib.nameValuePair "dump-${name}" {
        onCalendar = "*-*-* 05:00:00 UTC";
        settings = {
          timestamp_format = "long";
          ssh_identity = key;
          ssh_user = "btrbk";
          snapshot_create = "no";
          snapshot_preserve_min = "all";
          target_preserve_min = "no";
          target_preserve = t.keep;
          volume."ssh://${source.address}${source.volume}" = {
            snapshot_dir = source.snapshotDir;
            target = "${mount name}/nest";
            subvolume = lib.genAttrs source.shares (_: { });
          };
        };
      }) mine;
      systemd.services = lib.mkMerge [
        (lib.mapAttrs' (name: _: lib.nameValuePair "btrbk-dump-${name}" {
          unitConfig.RequiresMountsFor = [ (mount name) ];
          requires = [ "dump-key.service" ];
          after = [ "dump-key.service" "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig.ExecStartPre = "+${pkgs.coreutils}/bin/install -d -m 0755 ${mount name}/nest";
        }) mine)
        # Every five minutes, a report for status.bresilla.com.
        (lib.mapAttrs' (name: _: lib.nameValuePair "dump-status-${name}" {
          description = "Write dump ${name}'s report for status.bresilla.com";
          serviceConfig = { Type = "oneshot"; Nice = 10; TimeoutStartSec = "2min"; };
          environment = {
            BTRFS_MOUNTS = mount name;
            COPIES = "${mount name}/nest";
            COPIES_MOUNT = mount name;
            BTRBK_CONF = "/etc/btrbk/dump-${name}.conf";
            WATCH_UNITS = "btrbk-dump-${name}.service ${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" (mount name))}.mount";
          };
          script = ''
            install -d -m 0755 ${reports}
            ${lib.getExe collect} ${reports}/${name}.json vitals disks btrfs_errors backups units
          '';
        }) mine)
        {
          # Its own key for nest, made once; the public half goes into targets.nix.
          dump-key = {
            description = "Make the key this machine pulls nest's snapshots with";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            script = ''
              install -d -m 0700 -o btrbk -g btrbk ${dirOf key}
              [ -f ${key} ] || ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "dump@${me}" -f ${key}
              chown btrbk:btrbk ${key} ${key}.pub
            '';
          };
          dump-status-http = {
            description = "Serve dump's reports to hive";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStartPre = "+${pkgs.coreutils}/bin/install -d -m 0755 ${reports}";
              ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${reports} --port 9102 --no-listing";
              Restart = "always";
              RestartSec = 5;
              DynamicUser = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              NoNewPrivileges = true;
            };
          };
        }
      ];
      systemd.timers = lib.mapAttrs' (name: _: lib.nameValuePair "dump-status-${name}" {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "5min"; };
      }) mine;
      # Only over the overlay, where hive reads it.
      networking.firewall.interfaces.netbird0.allowedTCPPorts = [ 9102 ];
    })

    # --- nest -----------------------------------------------------------------------------
    (lib.mkIf (me == source.host) {
      # Each target's key may list and send snapshots of the data pool, nothing else.
      services.btrbk.sshAccess = lib.mapAttrsToList (_: t: {
        inherit (t) key;
        roles = [ "source" "info" ];
        extraArgs = [ "--restrict-path" source.volume ];
      }) (lib.filterAttrs (_: t: t.key != "") btrbkTargets);

      # One restic job per restic target, from the newest snapshot of every share, bound
      # read-only at a fixed path so the repository sees one steady tree.
      services.restic.backups = lib.mapAttrs (name: t: {
        repository = t.repository;
        passwordFile = "/var/lib/dump/restic-${name}.pass";
        rcloneConfigFile = lib.mkIf (lib.hasPrefix "rclone:" t.repository) "/var/lib/dump/rclone.conf";
        initialize = true;
        paths = map (s: "${restic}/${s}") source.shares;
        pruneOpts = keepFlags t.keep;
        timerConfig = { OnCalendar = "*-*-* 05:30:00 UTC"; Persistent = true; };
        backupPrepareCommand = ''
          for s in ${toString source.shares}; do
            newest=$(ls -d ${source.volume}/${source.snapshotDir}/$s.* | sort | tail -1)
            mkdir -p ${restic}/$s
            mountpoint -q ${restic}/$s && umount ${restic}/$s
            mount --bind -o ro "$newest" ${restic}/$s
          done
        '';
        backupCleanupCommand = ''
          for s in ${toString source.shares}; do umount ${restic}/$s 2>/dev/null || true; done
        '';
      }) resticTargets;
    })
  ];
}
