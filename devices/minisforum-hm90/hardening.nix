# Host side of the container boundary: the containers share this kernel, so it
# exposes as little as possible to them.
{ config, lib, pkgs, ... }:
let
  # Memory and task ceilings per container, so neither can starve hive.
  limits = {
    gitea = { MemoryMax = "3G"; TasksMax = 2048; };
    cache = { MemoryMax = "8G"; TasksMax = 4096; };
    probe = { MemoryMax = "4G"; TasksMax = 2048; };
  };
  names = lib.attrNames limits;
  # Containers that run their own Nix daemon, for CI: a throwaway writable store
  # over their store view, emptied on every start, and builds sent to builders.
  ownNix = [ "probe" ];
  ownNixFlags = name: [
    "--overlay=/var/lib/nixos-containers/${name}.store/lower:/var/lib/nixos-containers/${name}.store/upper:/nix/store"
    "--tmpfs=/nix/var/nix/daemon-socket"
    "--tmpfs=/nix/var/nix/gcroots"
  ];
  # Inside such a container: register the paths it runs on, never build locally,
  # and take builders per system from a file the builders page writes.
  ownNixConfig = { config, pkgs, ... }: {
    systemd.services.store-register = {
      description = "Register the container's own paths in its store";
      unitConfig.DefaultDependencies = false;
      after = [ "local-fs.target" ];
      before = [ "nix-daemon.socket" "sockets.target" ];
      wantedBy = [ "sockets.target" ];
      serviceConfig.Type = "oneshot";
      script = "${config.nix.package}/bin/nix-store --load-db < /var/lib/container-store/registration";
    };
    systemd.services.builder-key = {
      description = "Key this container signs in to builders with";
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /var/lib/ci
        [ -e /var/lib/ci/builder_ed25519 ] || ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" \
          -C "${config.networking.hostName}-ci-builder" -f /var/lib/ci/builder_ed25519
      '';
    };
    # Its own daemon writes the store; files from hive's show as nobody here,
    # which logrotate refuses (the journal keeps the logs).
    boot.nixStoreMountOpts = [ "nodev" "nosuid" ];
    services.logrotate.enable = false;
    nix.settings = {
      max-jobs = 0;
      builders = lib.mkForce "@/var/lib/ci/machines";
      builders-use-substitutes = true;
      experimental-features = [ "nix-command" "flakes" ];
    };
    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "ci-builders-test";
        runtimeInputs = [ config.nix.package pkgs.bubblewrap pkgs.coreutils pkgs.gawk pkgs.systemd ];
        text = builtins.readFile ./ci-builders-test.sh;
        # The derivation is Nix, single-quoted on purpose.
        excludeShellChecks = [ "SC2016" ];
      })
    ];
  };
  # Kernel calls no service here uses that keep showing up in privilege escalations.
  callFilter = map (c: "--system-call-filter=~${c}") [
    "@obsolete" "@cpu-emulation" "@debug" "@swap" "@raw-io" "@reboot" "@module"
    "bpf" "userfaultfd" "keyctl" "add_key" "request_key"
  ];
  # Each container sees only its own closure as /nix/store, filled by its own
  # unit before the container's namespace exists.
  storeSync = pkgs.writeShellApplication {
    name = "container-store";
    runtimeInputs = [ pkgs.systemd config.nix.package pkgs.coreutils pkgs.gnugrep pkgs.util-linux ];
    text = builtins.readFile ./container-store.sh;
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
      # Nothing in a container hands its static nameservers to resolvconf.
      config = { config, ... }: {
        imports = lib.optional (lib.elem name ownNix) ownNixConfig;
        networking.resolvconf.extraConfig = "name_servers='${toString config.networking.nameservers}'";
      };
      extraFlags = [
        "--drop-capability=CAP_NET_RAW,CAP_MKNOD,CAP_AUDIT_CONTROL"
        "--no-new-privileges=yes"
        # Hive's store database would still list every path hive has.
        "--tmpfs=/nix/var/nix/db"
      ] ++ callFilter ++ lib.optionals (lib.elem name ownNix) (ownNixFlags name) ++ lib.optionals (nets ? ${name}) [
        # Without addresses the module asks for no veth pair; nspawn makes it directly.
        "--network-veth"
        "--drop-capability=CAP_NET_ADMIN"
      ];
    }) limits;
    systemd.services = lib.concatMapAttrs (name: cfg: {
      # Only the socket families the services inside use.
      "container@${name}" = {
        serviceConfig = cfg // {
          BindReadOnlyPaths = [ "/nix/var/nix/container-stores/${name}:/nix/store" ];
          RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" "AF_INET" "AF_INET6" ];
        };
        postStart = lib.mkIf (nets ? ${name}) (lib.mkAfter (linkUp name nets.${name}));
        requires = [ "container-store-${name}.service" ];
        after = [ "container-store-${name}.service" ];
      };
      "container-store-${name}" = {
        description = "Store view of container '${name}'";
        environment = { INSTANCE = name; } // lib.optionalAttrs (lib.elem name ownNix) { OWN_NIX = "1"; };
        serviceConfig = {
          Type = "oneshot";
          PrivateMounts = true;
          EnvironmentFile = "/etc/nixos-containers/${name}.conf";
          ExecStart = "${storeSync}/bin/container-store";
        };
      };
    }) limits // {
      # A switch skips containers that gave up after failing; a fixed config brings
      # them back. Store views of removed containers go.
      containers-up = {
        description = "Start containers that gave up";
        wantedBy = [ "multi-user.target" ];
        after = map (n: "container@${n}.service") names;
        restartTriggers = [ storeSync ] ++ map (n: config.environment.etc."nixos-containers/${n}.conf".text) names;
        serviceConfig.Type = "oneshot";
        script = lib.concatMapStrings (n: ''
          if systemctl is-failed -q container@${n}; then
            systemctl reset-failed container@${n}
            systemctl start --no-block container@${n}
          fi
        '') names + ''
          for d in /nix/var/nix/container-stores/* /var/lib/nixos-containers/*.store; do
            case " ${toString names} " in *" $(basename "$d" .store) "*) ;; *) umount -q "$d/lower" 2>/dev/null || true; rm -rf "$d" ;; esac
          done
        '';
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
          ${lib.concatMapStrings (n: ''
            iifname "ve-${n}" ip daddr 100.64.0.0/10 tcp dport 22 accept
          '') ownNix}
          iifname "ve-*" ip daddr @private4 drop
        }
        # CI containers reach builders over NetBird as hive.
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          oifname "netbird0" ip saddr 10.231.0.0/16 masquerade
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
