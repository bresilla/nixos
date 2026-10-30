{ pkgs, ... }:
let
  # atticd inside; 524288 + 3001 = 527289 owns the chunk files on nest.
  uid = 3001;
  idBase = 524288;
  hostAddress = "10.231.1.1";
  address = "10.231.1.2";
  netbird = "100.68.233.203";
in {
  # Chunks live on nest; databases, pins and secrets stay in the container on hive's mirror.
  fileSystems."/mnt/nest/attic" = {
    device = "nest.link:/data/attic";
    fsType = "nfs4";
    options = [ "_netdev" "nofail" "noatime" ];
  };
  # Never start on an empty mount point, or chunks would land on hive.
  systemd.services."container@cache".unitConfig.RequiresMountsFor = [ "/mnt/nest/attic" ];

  services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress = {
    "cache.bresilla.com" = "http://${address}:8080";
  };

  # Pushes over Cloudflare's 100 MB cap come straight in over NetBird, and only there.
  systemd.sockets.cache-netbird = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "${netbird}:8080" ];
    socketConfig.FreeBind = true;
  };
  systemd.services.cache-netbird = {
    requires = [ "container@cache.service" ];
    after = [ "container@cache.service" ];
    serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${address}:8080";
  };

  # Outbound only (pins on GitHub); nothing outside hive can open a connection to it.
  networking.nat = { enable = true; internalInterfaces = [ "ve-cache" ]; externalInterface = "enp4s0"; };

  # Account management from hive: `sudo cache-ui-user add <name>`, `remove <name>`, `list`.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "cache-ui-user" ''
      exec ${pkgs.nixos-container}/bin/nixos-container run cache -- cache-ui-user "$@"
    '')
  ];

  containers.cache = {
    autoStart = true;
    privateUsers = idBase;
    # Maps the container's own files on the fly instead of rewriting their owners.
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    inherit hostAddress;
    localAddress = address;
    bindMounts."/srv/attic" = { hostPath = "/mnt/nest/attic"; isReadOnly = false; };
    config = import ./service.nix { proxy = hostAddress; inherit uid; };
  };
}
