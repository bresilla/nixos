# Nest's part of status.bresilla.com: every five minutes a report of its disks, RAID,
# backups and units, served read-only to hive over the direct link and nowhere else.
{ lib, pkgs, ... }:
let
  reports = "/run/nest-status";
  collect = pkgs.writeShellApplication {
    name = "status-collect";
    runtimeInputs = with pkgs; [ systemd jq coreutils util-linux openssl findutils gawk gnused gnugrep btrfs-progs smartmontools sqlite curl ];
    text = builtins.readFile ../../../services/status/collect.sh;
  };
in {
  systemd.services.nest-status = {
    description = "Write nest's report for status.bresilla.com";
    serviceConfig = { Type = "oneshot"; Nice = 10; TimeoutStartSec = "3min"; };
    environment = {
      BTRFS_MOUNTS = "/ /nix /home /mnt/data-store";
      SCRUB_MOUNTS = "/mnt/data-store";
      SNAPSHOTS = "/mnt/data-store/.snapshots";
      BTRBK_CONF = "/etc/btrbk/hourly.conf";
    };
    script = ''
      install -d -m 0755 ${reports}
      ${lib.getExe collect} ${reports}/nest.json disks raid smart btrfs_errors scrub backups nix_store
    '';
  };
  systemd.timers.nest-status = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "5min"; };
  };

  # Every 30 s, the parts that change by the minute; quiet in the journal unless something goes wrong.
  systemd.services.nest-status-live = {
    description = "Write nest's live state for status.bresilla.com";
    serviceConfig = { Type = "oneshot"; Nice = 5; TimeoutStartSec = "25s"; LogLevelMax = "notice"; };
    environment.WATCH_UNITS = "mnt-data\\x2dstore.mount nfs-server.service";
    script = ''
      install -d -m 0755 ${reports}
      ${lib.getExe collect} ${reports}/nest-live.json failed timers units vitals
    '';
  };
  systemd.timers.nest-status-live = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "30s"; OnUnitActiveSec = "30s"; AccuracySec = "1s"; };
  };

  # Hourly, the slow part: every share's size and what its snapshots and copies hold.
  systemd.services.nest-status-sizes = {
    description = "Measure the shares' disk use for status.bresilla.com";
    serviceConfig = { Type = "oneshot"; Nice = 19; IOSchedulingClass = "idle"; TimeoutStartSec = "30min"; };
    environment.DATA_TOP = "/mnt/data-store";
    script = ''
      install -d -m 0755 ${reports}
      ${lib.getExe collect} ${reports}/nest-sizes.json shares_du
    '';
  };
  systemd.timers.nest-status-sizes = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5min"; OnCalendar = "hourly"; };
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
