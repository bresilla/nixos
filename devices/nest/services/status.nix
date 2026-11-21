# Nest's part of status.bresilla.com: every five minutes a report of its disks, RAID,
# backups and units, served read-only to hive over the direct link and nowhere else.
{ lib, pkgs, ... }:
let
  reports = "/run/nest-status";
  collect = pkgs.writeShellApplication {
    name = "status-collect";
    runtimeInputs = with pkgs; [ systemd jq coreutils util-linux openssl findutils gawk gnused btrfs-progs smartmontools ];
    text = builtins.readFile ../../../services/status/collect.sh;
  };
in {
  systemd.services.nest-status = {
    description = "Write nest's report for status.bresilla.com";
    serviceConfig = { Type = "oneshot"; Nice = 10; TimeoutStartSec = "3min"; };
    environment = {
      BTRFS_MOUNTS = "/ /nix /home /mnt/data-store /mnt/backup";
      SCRUB_MOUNTS = "/mnt/data-store /mnt/backup";
      SNAPSHOTS = "/mnt/data-store/.snapshots";
      COPIES = "/mnt/backup";
      WATCH_UNITS = "systemd-cryptsetup@backup.service mnt-backup.mount mnt-data\\x2dstore.mount nfs-server.service";
    };
    script = ''
      install -d -m 0755 ${reports}
      ${lib.getExe collect} ${reports}/nest.json failed timers units disks raid smart btrfs_errors scrub backups
    '';
  };
  systemd.timers.nest-status = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "5min"; };
  };

  systemd.services.nest-status-http = {
    description = "Serve nest's report to hive";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${reports} --addr 10.99.0.2 --port 9101 --no-listing";
      Restart = "always";
      RestartSec = 5;
      DynamicUser = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
    };
  };
  systemd.tmpfiles.rules = [ "d ${reports} 0755 root root -" ];
  networking.firewall.interfaces.enp1s0.allowedTCPPorts = [ 9101 ];
}
