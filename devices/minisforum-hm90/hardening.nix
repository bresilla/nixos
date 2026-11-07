# Host side of the container boundary: the containers share this kernel, so it
# exposes as little as possible to them.
{ config, lib, pkgs, ... }:
let
  # Memory and task ceilings per container, so neither can starve hive.
  limits = {
    gitea = { MemoryMax = "3G"; TasksMax = 2048; };
    cache = { MemoryMax = "8G"; TasksMax = 4096; };
  };
  # Each container's network namespace belongs to hive, which sets its address,
  # so the container needs no say over its network at all.
  netns = name: let c = config.containers.${name}; in {
    description = "Network namespace of the ${name} container";
    before = [ "container@${name}.service" ];
    path = [ pkgs.iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "${pkgs.iproute2}/bin/ip netns delete ${name}";
    };
    script = ''
      ip netns delete ${name} 2>/dev/null || true
      ip link delete ve-${name} 2>/dev/null || true
      ip netns add ${name}
      ip link add ve-${name} type veth peer name eth0 netns ${name}
      ip -n ${name} link set lo up
      ip -n ${name} link set eth0 up
      ip -n ${name} addr add ${c.localAddress} dev eth0
      ip -n ${name} route add ${c.hostAddress} dev eth0
      ip -n ${name} route add default via ${c.hostAddress}
      ip link set ve-${name} up
      ip addr add ${c.hostAddress} dev ve-${name}
      ip route add ${c.localAddress} dev ve-${name}
    '';
  };
  # Containers whose network hive sets up; the others still configure their own.
  hostNet = [ "gitea" ];
  owned = name: builtins.elem name hostNet;
in {
  # Capabilities no service inside needs, no gaining privileges through setuid,
  # and for hive-owned networks no control over the network either.
  containers = lib.mapAttrs (name: _: {
    extraFlags = [
      "--drop-capability=CAP_NET_RAW,CAP_MKNOD,CAP_AUDIT_CONTROL"
      "--no-new-privileges=yes"
    ] ++ lib.optional (owned name) "--drop-capability=CAP_NET_ADMIN";
  } // lib.optionalAttrs (owned name) {
    privateNetwork = lib.mkForce false;
    networkNamespace = "/run/netns/${name}";
  }) limits;
  systemd.services = lib.mapAttrs' (name: cfg: lib.nameValuePair "container@${name}" ({
    serviceConfig = cfg;
  } // lib.optionalAttrs (owned name) {
    bindsTo = [ "netns-${name}.service" ];
    partOf = [ "netns-${name}.service" ];
    after = [ "netns-${name}.service" ];
  })) limits
  // lib.listToAttrs (map (name: lib.nameValuePair "netns-${name}" (netns name)) hostNet);

  # The containers see the daemon socket; their shifted uids may not use it.
  nix.settings.allowed-users = [ "root" "@wheel" ];

  # io_uring is a frequent source of kernel exploits and nothing here uses it.
  boot.kernel.sysctl."kernel.io_uring_disabled" = 2;

  # Rare network protocols load on demand when any process opens their socket.
  boot.blacklistedKernelModules = [
    "6lowpan" "appletalk" "atm" "ax25" "batman_adv" "caif" "hsr" "ieee802154"
    "ieee802154_6lowpan" "kcm" "l2tp_core" "l2tp_eth" "l2tp_ip" "l2tp_ip6"
    "l2tp_netlink" "l2tp_ppp" "lapb" "mac802154" "netrom" "nfc" "openvswitch"
    "phonet" "qrtr" "rds" "rds_tcp" "rose" "rxrpc" "sctp" "smc" "tipc" "x25"
  ];

  # Containers reach the internet only: not hive, the LAN, nest, the VPNs or each other.
  networking.nftables.tables.containers = {
    family = "inet";
    content = ''
      set private4 {
        type ipv4_addr; flags interval
        elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
                     172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }
      }
      chain input {
        type filter hook input priority filter; policy accept;
        iifname "ve-*" ct state established,related accept
        iifname "ve-*" drop
      }
      chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "ve-*" ct state established,related accept
        iifname "ve-*" meta nfproto ipv6 drop
        iifname "ve-*" ip daddr @private4 drop
      }
    '';
  };

  # Read-only report on the containers' boundary, runnable without a password.
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "hive-check";
      runtimeInputs = [ pkgs.systemd pkgs.nixos-container pkgs.coreutils pkgs.gnugrep pkgs.procps ];
      text = builtins.readFile ./hive-check.sh;
      # The probe is single-quoted on purpose: it expands inside the container.
      excludeShellChecks = [ "SC2016" ];
    })
  ];
  security.sudo.extraRules = [{
    groups = [ "wheel" ];
    commands = [{ command = ''/run/current-system/sw/bin/hive-check ""''; options = [ "NOPASSWD" ]; }];
  }];
}
