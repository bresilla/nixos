{
  config,
  lib,
  pkgs,
  ...
}:
let
  netbird = config.bresilla.services.netbird;
  tailscale = config.bresilla.services.tailscale;
  zerotier = config.bresilla.services.zerotier;
  wireguard = config.bresilla.services.wireguard;
  vpn = config.bresilla.services.vpnClients;
  innernet = config.bresilla.services.innernet;
in
{
  options.bresilla.services.netbird = {
    enable = lib.mkEnableOption "NetBird VPN client" // {
      default = true;
    };

    routingFeatures = lib.mkOption {
      type = lib.types.enum [
        "none"
        "client"
        "server"
        "both"
      ];
      default = "none";
      description = "NetBird routing feature mode.";
    };
  };

  options.bresilla.services.tailscale = {
    enable = lib.mkEnableOption "Tailscale mesh VPN" // {
      default = true;
    };
  };

  options.bresilla.services.zerotier = {
    enable = lib.mkEnableOption "ZeroTier network client" // {
      default = true;
    };
  };

  options.bresilla.services.wireguard = {
    enable = lib.mkEnableOption "WireGuard support" // {
      default = true;
    };
  };

  options.bresilla.services.innernet = {
    enable = lib.mkEnableOption "innernet networks run from hive (net.bresilla.com)" // {
      default = true;
    };
    networks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "skynet0" ];
      description = "Networks joined once their invitation is installed; each is its own interface of that name.";
    };
  };

  options.bresilla.services.vpnClients = {
    mullvad = {
      enable = lib.mkEnableOption "Mullvad VPN runtime support";
      autostart = lib.mkEnableOption "Mullvad VPN daemon boot autostart";
      gui.enable = lib.mkEnableOption "Mullvad VPN GUI package";
      excludeWrapper.enable = lib.mkEnableOption "mullvad-exclude setuid wrapper";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf netbird.enable {
      services.netbird = {
        enable = true;
        useRoutingFeatures = netbird.routingFeatures;
        clients.default = {
          interface = "netbird0";
          config.DisableDNS = true;
        };
      };

      # Not trusted as a whole: a peer reaches only what a machine opens on netbird0
      # (ssh is open everywhere; RDP and hive's cache open their own ports).
    })

    (lib.mkIf tailscale.enable {
      services.tailscale = {
        enable = true;
        interfaceName = "tailscale0";
        # Its default netfilter rules drop all 100.64.0.0/10 traffic not on
        # tailscale0, which includes NetBird; NixOS's firewall decides instead.
        extraSetFlags = [ "--netfilter-mode=nodivert" ];
      };
      # Not trusted as a whole either: only what a machine opens on tailscale0.
    })

    # Joined networks and the node identity stay in /var/lib/zerotier-one.
    (lib.mkIf zerotier.enable {
      services.zerotierone.enable = true;
    })

    # A network comes up only once `sudo innernet install --default-name --no-write-hosts
    # <invitation>` has written /etc/innernet/<network>.conf; until then nothing runs.
    (lib.mkIf innernet.enable {
      environment.systemPackages = [ pkgs.innernet ];
      systemd.services = lib.listToAttrs (map (net: {
        name = "innernet-${net}";
        value = {
          description = "innernet network ${net}";
          after = [ "network-online.target" "nss-lookup.target" ];
          wants = [ "network-online.target" "nss-lookup.target" ];
          wantedBy = [ "multi-user.target" ];
          unitConfig.ConditionPathExists = "/etc/innernet/${net}.conf";
          serviceConfig = {
            # /etc/hosts belongs to NixOS; names come from shared/system/hosts.nix.
            ExecStart = "${pkgs.innernet}/bin/innernet up ${net} --daemon --interval 60 --no-write-hosts";
            Restart = "always";
            RestartSec = 10;
          };
        };
      }) innernet.networks);
      # Its interfaces are innernet's alone.
      networking.networkmanager.unmanaged = map (net: "interface-name:${net}") innernet.networks;
      # Not trusted as a whole: peers reach only what a machine opens on these.
    })

    (lib.mkIf wireguard.enable {
      networking.wireguard.enable = true;
    })

    (lib.mkIf vpn.mullvad.enable {
      services.mullvad-vpn = {
        enable = true;
        package = if vpn.mullvad.gui.enable then pkgs.mullvad-vpn else pkgs.mullvad;
        enableEarlyBootBlocking = false;
        enableExcludeWrapper = vpn.mullvad.excludeWrapper.enable;
      };

      systemd.services.mullvad-daemon.wantedBy = lib.mkIf (!vpn.mullvad.autostart) (lib.mkForce [ ]);
    })
  ];
}
