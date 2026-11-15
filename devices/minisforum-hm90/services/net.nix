# innernet on hive: the coordinating servers of the skynet<n> networks and their
# page, net.bresilla.com, which only peers reach. The router forwards each network's
# UDP port here; everything else about a network is decided on the page.
# Rebuilding one on another machine needs only its two copies in gopass (README.md).
{ lib, pkgs, ... }:
let
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
  pki = ../../../shared/system/pki;
  caReady = builtins.pathExists (pki + "/bresilla-root.crt");
  ports = lib.mapAttrsToList (_: n: n.port) networks;
  inside = net: "/var/lib/nixos-containers/net/var/lib/net-backup/${net}";
  # Readable by bresilla for gopass; only encrypted copies ever land here.
  outside = net: "/var/lib/net-backup/${net}";
in {
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-net" ];
    externalInterface = "enp4s0";
    forwardPorts = map (port: { sourcePort = port; destination = "${address}:${toString port}"; proto = "udp"; }) ports;
  };
  # innernet makes and changes its interfaces itself, so this container alone keeps
  # network control, over its own namespace.
  hive.containerNet.net = { host = hostAddress; local = address; netAdmin = true; lanUdpPorts = ports; };

  # Each new encrypted copy goes out for gopass and, by date, to nest (id.nix's
  # mount, beside the vault's) for 30 days.
  systemd.services = lib.mapAttrs' (net: _: lib.nameValuePair "net-backup-copy-${net}" {
    description = "Copy ${net}'s encrypted key and database out of its container";
    serviceConfig = { Type = "oneshot"; Nice = 10; };
    path = [ pkgs.coreutils pkgs.findutils pkgs.util-linux ];
    script = ''
      [ -d ${inside net} ] || exit 0
      install -d -m 0755 /var/lib/net-backup ${outside net}
      for f in ${inside net}/*.age; do
        [ -f "$f" ] || continue
        cmp -s "$f" "${outside net}/$(basename "$f")" || install -m 0644 "$f" "${outside net}/$(basename "$f")"
      done
      mountpoint -q /mnt/nest/id || exit 0
      dst=/mnt/nest/id/net/${net}/$(date -u +%F)
      install -d -m 0700 "$dst"
      cp --preserve=timestamps ${outside net}/*.age "$dst"/ 2>/dev/null || true
      find /mnt/nest/id/net/${net} -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
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

  containers.net = {
    autoStart = true;
    privateUsers = 524288;
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    config = {
      imports = [ ../../../shared/services/server/net ];
      bresilla.services.net = {
        networks = lib.mapAttrs (_: n: n // { endpoint = "ddns.bresilla.net:${toString n.port}"; }) networks;
        domain = "net.bresilla.com";
        login = {
          issuer = "https://id.bresilla.com/oauth2/openid/net";
          client = "net";
          envFile = "/var/lib/oidc/proxy.env";
          adminClaim = "net_role";
        };
        caChecker = "10.231.6.2";
        ca = lib.mkIf caReady {
          name = "cert.bresilla.com";
          address = "10.231.6.2";
          directory = "https://cert.bresilla.com:8443/acme/acme/directory";
          root = pki + "/bresilla-root.crt";
        };
        # The same two YubiKeys gopass encrypts to.
        backup.recipients = [
          "age1yubikey1q03sjfgkj7l25va4uhh87gtm5dj3a5f27497ghyrpdzzqe8uagjf5ehtkjf"
          "age1yubikey1qdj8xer5fmxh6nxnenpfkw20l0ekmr9nzhfe2xpcsrdctv7u63pj2r62rzc"
        ];
      };
    };
  };
}
