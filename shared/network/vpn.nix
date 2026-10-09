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

      networking.firewall.trustedInterfaces = [ "netbird0" ];
    })

    (lib.mkIf tailscale.enable {
      services.tailscale = {
        enable = true;
        interfaceName = "tailscale0";
      };
      networking.firewall.trustedInterfaces = [ "tailscale0" ];
    })

    # Joined networks and the node identity stay in /var/lib/zerotier-one.
    (lib.mkIf zerotier.enable {
      services.zerotierone.enable = true;
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
