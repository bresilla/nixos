# status.bresilla.com on hive: what failed and what is fine, on hive and nest. Only the
# overlay reaches it (overlay.nix), signed in through id.bresilla.com. Every five
# minutes hive writes its own report and takes nest's over the direct link; the
# container only reads the two.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.server.status;
  domain = "status.bresilla.com";
  hostAddress = "10.231.8.1";
  address = "10.231.8.2";
  reports = "/var/lib/status";
  pki = ../../shared/system/pki;
  caReady = builtins.pathExists (pki + "/bresilla-root.crt");
  collect = pkgs.writeShellApplication {
    name = "status-collect";
    runtimeInputs = with pkgs; [ systemd jq coreutils util-linux openssl findutils gawk gnused gnugrep btrfs-progs smartmontools sqlite curl ];
    text = builtins.readFile ./collect.sh;
  };
  # Each site as it is served: the overlay's from their containers, the rest from outside.
  certs = [
    "vault.bresilla.com=10.231.5.2:443"
    "cert.bresilla.com=10.231.6.2:8443"
    "net.bresilla.com=10.231.7.2:443"
    "${domain}=${address}:443"
    "id.bresilla.com=id.bresilla.com:443"
    "git.bresilla.com=git.bresilla.com:443"
    "cache.bresilla.com=cache.bresilla.com:443"
    "build.bresilla.com=build.bresilla.com:443"
    "s3.bresilla.com=s3.bresilla.com:443"
  ];
  roots = [ "bresilla-root=${pki}/bresilla-root.crt" "bresilla-intermediate=${pki}/bresilla-intermediate.crt" ];
  # A report, taken only when it is whole; an old one shows its age on the page.
  fetchFrom = url: file: ''
    if curl -sf --max-time 30 ${url} -o ${reports}/${file}.new && jq -e .at ${reports}/${file}.new > /dev/null; then
      chmod 0644 ${reports}/${file}.new && mv ${reports}/${file}.new ${reports}/${file}
    fi
    rm -f ${reports}/${file}.new
  '';
  fetch = name: fetchFrom "http://nest.link:9101/${name}" name;
  # The dump targets (services/dump/targets.nix); each btrbk one serves its report over NetBird.
  dumpTargets = (import ../dump/targets.nix).targets;
  fetchDump = lib.concatStrings (lib.mapAttrsToList (name: t:
    fetchFrom "http://${t.host}.netbird:9102/${name}.json" "dump-${name}.json")
    (lib.filterAttrs (_: t: t.kind == "btrbk") dumpTargets));
  # One line per hour of every size, kept 90 days, for the page's growth charts.
  history = pkgs.writeText "status-history.jq" ''
    def by(k; v): map({(k): v}) | add // {};
    {at: now | floor,
     shares: ($ns.live // [] | by(.share; .total)),
     snapshots: ($ns.snapshots // [] | by(.share; .exclusive)),
     drive: ($ns.drive // [] | by(.share; .exclusive)),
     disks: ((($h.disks // []) | by("hive:" + .target; .used)) + (($n.disks // []) | by("nest:" + .target; .used))),
     cache: ($h.cache_stats.caches // [] | by(.name; .size)),
     chunks: ([$h.cache_stats.chunks // [] | .[] | select(.state == "V") | .size] | add // 0),
     nix: {hive: $h.nix_store.size, nest: $n.nix_store.size},
     containers: ($hs.container_disk // [] | by(.name; .size))}
  '';
in {
  options.bresilla.server.status.enable = lib.mkEnableOption "the status page, status.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "status" ];
    bresilla.server.overlay.sites.${domain} = "${address}:443";
    networking.nat = { enable = true; internalInterfaces = [ "ve-status" ]; externalInterface = "enp4s0"; };
    bresilla.server.containerNet.status = { host = hostAddress; local = address; };
    systemd.tmpfiles.rules = [ "d ${reports} 0755 root root -" ];

    systemd.services.status-collect = {
      description = "Write hive's report and fetch nest's, for ${domain}";
      serviceConfig = { Type = "oneshot"; Nice = 10; TimeoutStartSec = "3min"; };
      environment = {
        CERTS = toString certs;
        ROOTS = lib.optionalString caReady (toString roots);
        CACHE_DB = "/var/lib/nixos-containers/cache/var/lib/atticd/server.db";
        CACHE_MACHINE = "cache";
        PINS_URL = "https://cache.bresilla.com/-/pins";
        BTRFS_MOUNTS = "/ /var/lib/nixos-containers";
      };
      path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
      script = ''
        install -d -m 0755 ${reports}
        ${lib.getExe collect} ${reports}/hive.json certs disks raid smart btrfs_errors nix_store cache_stats pins
        ${fetch "nest.json"}
        ${fetchDump}
      '';
    };
    systemd.timers.status-collect = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "5min"; };
    };

    # Every 30 s, the parts that change by the minute: units, containers, timers, load.
    # Quiet in the journal unless something goes wrong.
    systemd.services.status-live = {
      description = "Write hive's live state and fetch nest's, for ${domain}";
      serviceConfig = { Type = "oneshot"; Nice = 5; TimeoutStartSec = "25s"; LogLevelMax = "notice"; };
      path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
      script = ''
        install -d -m 0755 ${reports}
        ${lib.getExe collect} ${reports}/hive-live.json failed containers container_stats timers inner_timers vitals
        ${fetch "nest-live.json"}
      '';
    };
    systemd.timers.status-live = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "30s"; OnUnitActiveSec = "30s"; AccuracySec = "1s"; };
    };

    # Hourly at :20, once nest has measured its shares: each container's disk, nest's sizes, a line of history.
    systemd.services.status-sizes = {
      description = "Measure disk use for ${domain} and keep its history";
      after = [ "status-collect.service" ];
      serviceConfig = { Type = "oneshot"; Nice = 19; IOSchedulingClass = "idle"; TimeoutStartSec = "30min"; };
      path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
      script = ''
        ${lib.getExe collect} ${reports}/hive-sizes.json container_disk
        ${fetch "nest-sizes.json"}
        r=${reports}
        read_or() { [ -s "$1" ] && cat "$1" || echo '{}'; }
        jq -cn --argjson h "$(read_or $r/hive.json)" --argjson n "$(read_or $r/nest.json)" \
          --argjson hs "$(read_or $r/hive-sizes.json)" --argjson ns "$(read_or $r/nest-sizes.json | jq '.shares_du // {}')" \
          -f ${history} >> $r/history.jsonl
        cutoff=$(( $(date +%s) - 90 * 86400 ))
        jq -c --argjson c "$cutoff" 'select(.at > $c)' $r/history.jsonl > $r/history.new && chmod 0644 $r/history.new && mv $r/history.new $r/history.jsonl
      '';
    };
    systemd.timers.status-sizes = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "15min"; OnCalendar = "*:20"; };
    };

    containers.status = {
      autoStart = true;
      privateUsers = 524288;
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      bindMounts.${reports} = { hostPath = reports; isReadOnly = true; };
      config = {
        imports = [ ./. ];
        bresilla.services.status = {
          inherit domain;
          targets = lib.mapAttrs (_: t: { inherit (t) kind keep; host = t.host or null; }) dumpTargets;
          login = {
            issuer = "https://id.bresilla.com/oauth2/openid/status";
            client = "status";
            envFile = "/var/lib/oidc/proxy.env";
          };
          ca = lib.mkIf caReady {
            name = "cert.bresilla.com";
            address = "10.231.6.2";
            directory = "https://cert.bresilla.com:8443/acme/acme/directory";
            root = pki + "/bresilla-root.crt";
          };
        };
      };
    };
  };
}
