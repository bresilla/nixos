# Host side of the container boundary: the containers share this kernel, so it
# exposes as little as possible to them.
{ config, lib, pkgs, ... }:
let
  # Memory and task ceilings per container, so neither can starve hive.
  limits = {
    gitea = { MemoryMax = "3G"; TasksMax = 2048; };
    cache = { MemoryMax = "8G"; TasksMax = 4096; };
  };
  nets = config.hive.containerNet;
  ip = "${pkgs.iproute2}/bin/ip";
  # Hive sets both ends of the link once the container runs, so the container
  # itself never needs network control.
  linkUp = name: net: ''
    pid=$(${pkgs.systemd}/bin/machinectl show ${name} -p Leader --value)
    inside() { ${pkgs.util-linux}/bin/nsenter -t "$pid" -n ${ip} "$@"; }
    inside link set host0 name eth0
    inside link set eth0 up
    inside addr add ${net.local} dev eth0
    inside route add ${net.host} dev eth0
    inside route add default via ${net.host}
    ${ip} link set ve-${name} up
    ${ip} addr add ${net.host} dev ve-${name}
    ${ip} route add ${net.local} dev ve-${name}
  '';
in {
  options.hive.containerNet = lib.mkOption {
    description = "Each container's link to hive: hive's address and the container's.";
    default = { };
    type = lib.types.attrsOf (lib.types.submodule {
      options.host = lib.mkOption { type = lib.types.str; };
      options.local = lib.mkOption { type = lib.types.str; };
    });
  };

  config = {
    # Capabilities no service inside needs, and no gaining privileges through setuid.
    containers = lib.mapAttrs (name: _: {
      extraFlags = [
        "--drop-capability=CAP_NET_RAW,CAP_MKNOD,CAP_AUDIT_CONTROL"
        "--no-new-privileges=yes"
      ] ++ lib.optionals (nets ? ${name}) [
        # Without addresses the module asks for no veth pair; nspawn makes it directly.
        "--network-veth"
        "--drop-capability=CAP_NET_ADMIN"
      ];
    }) limits;
    systemd.services = lib.mapAttrs' (name: cfg: lib.nameValuePair "container@${name}" {
      serviceConfig = cfg;
      postStart = lib.mkIf (nets ? ${name}) (lib.mkAfter (linkUp name nets.${name}));
    }) limits // {
      # A switch skips containers that gave up after failing; a fixed config brings them back.
      containers-up = {
        description = "Start containers that gave up";
        wantedBy = [ "multi-user.target" ];
        after = map (n: "container@${n}.service") (lib.attrNames limits);
        restartTriggers = map (n: config.environment.etc."nixos-containers/${n}.conf".text) (lib.attrNames limits);
        serviceConfig.Type = "oneshot";
        script = lib.concatMapStrings (n: ''
          if systemctl is-failed -q container@${n}; then
            systemctl reset-failed container@${n}
            systemctl start --no-block container@${n}
          fi
        '') (lib.attrNames limits);
      };
    };

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

    # No module loads after boot. modules.txt is what hive uses (lsmod), loaded up
    # front so containers and firewall reloads still find theirs; add to it for new needs.
    security.lockKernelModules = true;
    boot.kernelModules = lib.filter (m: m != "") (lib.splitString "\n" (builtins.readFile ./modules.txt));

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
  };
}
