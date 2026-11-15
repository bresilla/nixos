# innernet on hive: the coordinating server of skynet0 (10.20.0.0/16) and its page,
# net.bresilla.com, which only peers of the network reach. The router forwards UDP
# 51820 here; everything else about the network is decided on the page.
# Rebuilding it on another machine needs only the two copies in gopass (README.md).
{ lib, pkgs, ... }:
let
  network = "skynet0";
  port = 51820;
  hostAddress = "10.231.7.1";
  address = "10.231.7.2";
  pki = ../../../shared/system/pki;
  caReady = builtins.pathExists (pki + "/bresilla-root.crt");
  inside = "/var/lib/nixos-containers/net/var/lib/net-backup/${network}";
  # Readable by bresilla for gopass; only encrypted copies ever land here.
  outside = "/var/lib/net-backup/${network}";
in {
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-net" ];
    externalInterface = "enp4s0";
    forwardPorts = [ { sourcePort = port; destination = "${address}:${toString port}"; proto = "udp"; } ];
  };
  # innernet makes and changes its interface itself, so this container alone keeps
  # network control, over its own namespace.
  hive.containerNet.net = { host = hostAddress; local = address; netAdmin = true; };

  # Each new encrypted copy goes out for gopass and, by date, to nest (id.nix's
  # mount, beside the vault's) for 30 days.
  systemd.services.net-backup-copy = {
    description = "Copy ${network}'s encrypted key and database out of its container";
    serviceConfig = { Type = "oneshot"; Nice = 10; };
    path = [ pkgs.coreutils pkgs.findutils pkgs.util-linux ];
    script = ''
      [ -d ${inside} ] || exit 0
      install -d -m 0755 /var/lib/net-backup ${outside}
      for f in ${inside}/*.age; do
        [ -f "$f" ] || continue
        cmp -s "$f" "${outside}/$(basename "$f")" || install -m 0644 "$f" "${outside}/$(basename "$f")"
      done
      mountpoint -q /mnt/nest/id || exit 0
      dst=/mnt/nest/id/net/$(date -u +%F)
      install -d -m 0700 "$dst"
      cp --preserve=timestamps ${outside}/*.age "$dst"/ 2>/dev/null || true
      find /mnt/nest/id/net -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
    '';
  };
  systemd.paths.net-backup-copy = {
    wantedBy = [ "paths.target" ];
    pathConfig = { PathChanged = [ "${inside}/db.age" "${inside}/server.age" ]; };
  };
  systemd.timers.net-backup-copy = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "04:30 UTC"; Persistent = true; };
  };

  containers.net = {
    autoStart = true;
    privateUsers = 524288;
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    config = {
      imports = [ ../../../shared/services/server/net ];
      bresilla.services.net = {
        inherit network port;
        cidr = "10.20.0.0/16";
        endpoint = "ddns.bresilla.net:${toString port}";
        domain = "net.bresilla.com";
        groups = {
          servers = "10.20.1.0/24";
          laptops = "10.20.2.0/24";
          ci = "10.20.3.0/24";
          devices = "10.20.4.0/24";
        };
        access = [ [ "laptops" "servers" ] [ "laptops" "devices" ] [ "ci" "servers" ] ];
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
