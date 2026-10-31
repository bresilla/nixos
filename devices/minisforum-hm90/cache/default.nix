{ pkgs, ... }:
let
  # atticd inside; 524288 + 3001 = 527289 owns the chunk files on nest.
  uid = 3001;
  idBase = 524288;
  hostAddress = "10.231.1.1";
  address = "10.231.1.2";
  wireguard = "10.77.0.1";
  wireguardPort = 51821;
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

  # CI's way in, through UDP 51821 forwarded on the router. One peer per repo and
  # architecture, as runners sharing a key would knock each other off.
  networking.wireguard.interfaces.wg-ci = {
    ips = [ "${wireguard}/24" ];
    listenPort = wireguardPort;
    privateKeyFile = "/var/lib/wireguard/wg-ci.key";
    generatePrivateKeyFile = true;
    peers = [
      { name = "nixos-x86"; publicKey = "4Gi9YLZ2u4ai8VtkPNBPI1vwsLuDJiP6Prq6iHPh2wo="; allowedIPs = [ "10.77.0.2/32" ]; }
      { name = "nixos-arm"; publicKey = "otfyGWf7uUNL0KeRuYy0CLFQLVRYuZCOnHvQKzolyW0="; allowedIPs = [ "10.77.0.3/32" ]; }
      { name = "devices-x86"; publicKey = "44W8ZHYmcGQrEXsBpnot4eqJMf0aLHxZnGZJp+w6CjM="; allowedIPs = [ "10.77.0.4/32" ]; }
      { name = "devices-arm"; publicKey = "ia5pBIzX+XB2udTfFwCSu6upi6Pz5J5QUteLijqzsks="; allowedIPs = [ "10.77.0.5/32" ]; }
      { name = "goku-x86"; publicKey = "PyjUf+2jwFxygcfpNkC1E5QQWkqI6zlCKFGiCwC1FQY="; allowedIPs = [ "10.77.0.6/32" ]; }
      { name = "goku-arm"; publicKey = "dA5XQpmDKLYjABiWAvwHiE5clJ89Y1sM9YJLUA8b+Xk="; allowedIPs = [ "10.77.0.7/32" ]; }
    ];
  };
  networking.firewall.allowedUDPPorts = [ wireguardPort ];
  # Peers reach the cache and nothing else on hive or the LAN.
  networking.firewall.interfaces.wg-ci.allowedTCPPorts = [ 8080 ];
  networking.nftables.tables.wg-ci = {
    family = "inet";
    content = ''
      chain forward {
        type filter hook forward priority filter;
        iifname "wg-ci" drop
      }
    '';
  };

  # Pushes over Cloudflare's 100 MB cap come straight in, and only here.
  systemd.sockets.cache-wireguard = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "${wireguard}:8080" ];
    socketConfig.FreeBind = true;
  };
  systemd.services.cache-wireguard = {
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
