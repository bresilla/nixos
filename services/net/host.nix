# innernet on hive: the coordinating servers of the skynet<n> networks and their
# page, net.bresilla.com, which only peers reach. The router forwards each network's
# UDP port here; everything else about a network is decided on the page.
# Rebuilding one on another machine needs only its two copies in gopass (README.md).
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.server.net;
  # Each network is its own interface of the same name, on its own port; 51821 is
  # CI's (cache.nix), so never one of these.
  networks = {
    skynet0 = {
      cidr = "10.20.0.0/16";
      port = 42793;
      groups = {
        servers = "10.20.1.0/24";
        laptops = "10.20.2.0/24";
        ci = "10.20.3.0/24";
        devices = "10.20.4.0/24";
      };
      access = [ [ "laptops" "servers" ] [ "laptops" "devices" ] [ "ci" "servers" ] ];
    };
  };
  hostAddress = "10.231.7.1";
  address = "10.231.7.2";
  pki = ../../shared/system/pki;
  caReady = builtins.pathExists (pki + "/bresilla-root.crt");
  ports = lib.mapAttrsToList (_: n: n.port) networks;
  inside = net: "/var/lib/nixos-containers/innernet/var/lib/net-backup/${net}";
  # Readable by bresilla for gopass; only encrypted copies ever land here.
  outside = net: "/var/lib/net-backup/${net}";
in {
  options.bresilla.server.net.enable = lib.mkEnableOption "innernet and its page, net.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "innernet" ];
    networking.nat = {
      enable = true;
      internalInterfaces = [ "ve-innernet" ];
      externalInterface = "enp4s0";
      forwardPorts = map (port: { sourcePort = port; destination = "${address}:${toString port}"; proto = "udp"; }) ports;
    };
    # innernet makes and changes its interfaces itself, so this container alone keeps
    # network control, over its own namespace.
    bresilla.server.containerNet.innernet = { host = hostAddress; local = address; netAdmin = true; lanUdpPorts = ports; };

    # Each new encrypted copy goes out for gopass and to net's share on nest: the
    # database by date for 30 days in data/, the server key as it is now in config/.
    fileSystems."/mnt/nest/net" = {
      device = "nest.link:/data/net";
      fsType = "nfs4";
      options = [ "_netdev" "nofail" "noatime" ];
    };
    systemd.services = lib.mapAttrs' (net: _: lib.nameValuePair "net-backup-copy-${net}" {
      description = "Copy ${net}'s encrypted key and database out of its container";
      serviceConfig = { Type = "oneshot"; Nice = 10; };
      path = [ pkgs.coreutils pkgs.findutils pkgs.util-linux pkgs.diffutils ];
      script = ''
        [ -d ${inside net} ] || exit 0
        install -d -m 0755 /var/lib/net-backup ${outside net}
        for f in ${inside net}/*.age; do
          [ -f "$f" ] || continue
          cmp -s "$f" "${outside net}/$(basename "$f")" || install -m 0644 "$f" "${outside net}/$(basename "$f")"
        done
        mountpoint -q /mnt/nest/net || { echo "nest's net share is not mounted" >&2; exit 1; }
        if [ -f ${outside net}/server.age ]; then
          install -d -m 0700 /mnt/nest/net/config/${net}
          cmp -s ${outside net}/server.age /mnt/nest/net/config/${net}/server.age ||
            install -m 0600 ${outside net}/server.age /mnt/nest/net/config/${net}/server.age
        fi
        [ -f ${outside net}/db.age ] || exit 0
        dst=/mnt/nest/net/data/${net}/$(date -u +%F)
        install -d -m 0700 "$dst"
        cp --preserve=timestamps ${outside net}/db.age "$dst"/
        find /mnt/nest/net/data/${net} -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
      '';
    }) networks;
    systemd.paths = lib.mapAttrs' (net: _: lib.nameValuePair "net-backup-copy-${net}" {
      wantedBy = [ "paths.target" ];
      pathConfig.PathChanged = [ "${inside net}/db.age" "${inside net}/server.age" ];
    }) networks;
    systemd.timers = lib.mapAttrs' (net: _: lib.nameValuePair "net-backup-copy-${net}" {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "04:30 UTC"; Persistent = true; };
    }) networks;

    # Not "net": a running container's name resolves locally, and would swallow all of .net.
    containers.innernet = {
      autoStart = true;
      privateUsers = 524288;
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      config = {
        imports = [ ./. ];
        bresilla.services.net = {
          networks = lib.mapAttrs (_: n: n // { endpoint = "ddns.bresilla.net:${toString n.port}"; }) networks;
          domain = "net.bresilla.com";
          login = {
            issuer = "https://id.bresilla.com/oauth2/openid/net";
            client = "net";
            envFile = "/var/lib/oidc/proxy.env";
            adminClaim = "net_role";
          };
          # The CA, and hive for the status page: hive reaches containers from its
          # link-local address, which only its end of this link can have.
          checkers = [ "10.231.6.2" "169.254.0.0/16" ];
          ca = lib.mkIf caReady {
            name = "cert.bresilla.com";
            address = "10.231.6.2";
            directory = "https://cert.bresilla.com:8443/acme/acme/directory";
            root = pki + "/bresilla-root.crt";
          };
          # The same two YubiKeys gopass encrypts to.
          backup.recipients = config.bresilla.server.recipients;
        };
      };
    };
  };
}
