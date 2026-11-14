{ pkgs, pkgsUnstable, ... }:
let
  # rustfs inside; 524288 + 3002 = 527290 owns the buckets on nest.
  uid = 3002;
  idBase = 524288;
  hostAddress = "10.231.4.1";
  address = "10.231.4.2";
  netbird = "100.68.233.203";
in {
  # Buckets live on nest; the root key and RustFS's logs stay in the container.
  fileSystems."/mnt/nest/s3" = {
    device = "nest.link:/data/s3";
    fsType = "nfs4";
    options = [ "_netdev" "nofail" "noatime" ];
  };
  # Never start on an empty mount point, or buckets would land on hive.
  systemd.services."container@s3".unitConfig.RequiresMountsFor = [ "/mnt/nest/s3" ];

  services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress = {
    "s3.bresilla.com" = "http://${address}:80";
  };

  # S3 clients on NetBird skip Cloudflare's 100 MB cap on a single upload.
  networking.firewall.interfaces.netbird0.allowedTCPPorts = [ 9000 ];
  systemd.sockets.s3-netbird = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "${netbird}:9000" ];
    socketConfig.FreeBind = true;
  };
  systemd.services.s3-netbird = {
    requires = [ "container@s3.service" ];
    after = [ "container@s3.service" ];
    serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${address}:80";
  };

  # Outbound only (id.bresilla.com's keys); nothing outside hive can open a connection to it.
  networking.nat = { enable = true; internalInterfaces = [ "ve-s3" ]; externalInterface = "enp4s0"; };
  # Hive sets this link from outside, so the container needs no network control.
  hive.containerNet.s3 = { host = hostAddress; local = address; };

  containers.s3 = {
    autoStart = true;
    privateUsers = idBase;
    # Maps the container's own files on the fly instead of rewriting their owners.
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    bindMounts."/srv/s3" = { hostPath = "/mnt/nest/s3"; isReadOnly = false; };
    config = {
      imports = [ ../../../shared/services/server/s3 ];
      bresilla.services.s3 = {
        domain = "s3.bresilla.com"; proxy = hostAddress; inherit uid;
        # RustFS is not in nixos-26.05; unstable's comes prebuilt from cache.nixos.org.
        package = pkgsUnstable.rustfs;
        console = pkgsUnstable.rustfs.console;
        # Sign in with id.bresilla.com; hive puts the secret here.
        login = {
          name = "id.bresilla.com";
          discovery = "https://id.bresilla.com/oauth2/openid/s3/.well-known/openid-configuration";
          client = "s3";
          envFile = "/var/lib/oidc/s3.env";
          policyClaim = "s3_policy";
        };
      };
    };
  };
}
