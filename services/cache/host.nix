{ config, lib, pkgs, ... }:
let
  mnt = config.bresilla.server.storage.mount;
  cfg = config.bresilla.server.cache;
  # atticd inside; 524288 + 3001 = 527289 owns the chunk files on nest.
  uid = 3001;
  idBase = config.bresilla.server.idBase;
  hostAddress = "10.231.1.1";
  address = "10.231.1.2";
  netbird = config.bresilla.server.overlay.address;
  wireguard = "10.77.0.1";
  wireguardPort = 51821;
in {
  options.bresilla.server.cache.enable = lib.mkEnableOption "the binary cache, cache.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "cache" ];
    bresilla.server.keep.cache = [ "/var/lib/wireguard/wg-ci.key" "/var/lib/nixos-containers/cache/var/lib/atticd.env" "/var/lib/nixos-containers/cache/var/lib/cache-ui.env" ];
    bresilla.server.keepTo.cache = "${mnt}/cache/config";
    # Chunks live on nest; databases, pins and secrets stay in the container on hive's mirror.
    bresilla.server.shares."cache" = "cache";
    # The chunks are their own share, which btrbk leaves out; mounted inside the cache's
    # data/, so the container's /srv/attic carries it along.
    bresilla.server.shares."cache/data/storage" = "cache-chunks";
    # Never start on an empty mount point, or chunks would land on hive.
    systemd.services."container@cache".unitConfig.RequiresMountsFor = [ "${mnt}/cache" "${mnt}/cache/data/storage" ];

    services.cloudflared.tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de".ingress = {
      "cache.bresilla.com" = "http://${address}:8080";
    };

    # CI's way in, through UDP 51821 forwarded on the router. One peer per repo and
    # architecture, as runners sharing a key would knock each other off.
    networking.wireguard.interfaces.cicd0 = {
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
        # Builders the ci container sends builds to; they dial in and keep it open.
        { name = "tron"; publicKey = "7Yr8T3105aQjFHzwEtTIbu+on2kya4o2vmcTWVbpID8="; allowedIPs = [ "10.77.0.8/32" ]; }
        { name = "lama"; publicKey = "olm4qwS4dvleVzEpaL8hdgkJ90tAFpbAFliLCHSkr2o="; allowedIPs = [ "10.77.0.9/32" ]; }
      ];
    };
    networking.firewall.allowedUDPPorts = [ wireguardPort ];
    # Peers reach the cache and nothing else on hive or the LAN.
    networking.firewall.interfaces.cicd0.allowedTCPPorts = [ 8080 ];
    networking.nftables.tables.cicd0 = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority filter;
          iifname "cicd0" ct state established,related accept
          iifname "cicd0" drop
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

    # Machines push over NetBird: `attic` logins, and tron's builds.
    networking.firewall.interfaces.netbird0.allowedTCPPorts = [ 8080 ];
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
    networking.nat = { enable = true; internalInterfaces = [ "ve-cache" ]; };
    # Hive sets this link from outside, so the container needs no network control.
    bresilla.server.containerNet.cache = { host = hostAddress; local = address; };

    containers.cache = {
      autoStart = true;
      # Maps the container's own files on the fly instead of rewriting their owners.
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      bindMounts."/srv/attic" = { hostPath = "${mnt}/cache/data"; isReadOnly = false; };
      config = {
        imports = [ ./. ];
        bresilla.services.cache = {
          url = "https://cache.bresilla.com"; proxy = hostAddress; inherit uid;
          # Sign in with id.bresilla.com; hive puts the login secrets here.
          login = {
            issuer = "https://id.bresilla.com/oauth2/openid/cache";
            client = "cache";
            envFile = "/var/lib/oidc/proxy.env";
            adminClaim = "cache_role";
          };
        };
      };
    };
  };
}
