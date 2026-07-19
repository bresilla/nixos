{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.wur;
in
{
  options.bresilla.services.wur = {
    eduroam.enable = lib.mkEnableOption "WUR eduroam iwd profile";
  };

  config = lib.mkIf cfg.eduroam.enable {
    assertions = [
      {
        assertion = config.bresilla.secrets.enable;
        message = "bresilla.services.wur.eduroam needs bresilla.secrets.enable (the 8021x profile is a sops secret)";
      }
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/iwd 0700 root root -"
    ];

    networking.networkmanager.dispatcherScripts = [
      {
        source = pkgs.writeShellScript "wur-eduroam-routes" ''
          iface="$1"
          status="$2"

          [ "$status" = "up" ] || exit 0
          [ "$CONNECTION_ID" = "eduroam" ] || exit 0

          gw="$(${pkgs.iproute2}/bin/ip route show dev "$iface" default | ${pkgs.gawk}/bin/awk '{print $3; exit}')"
          [ -n "$gw" ] && ${pkgs.iproute2}/bin/ip route replace 10.90.0.0/16 via "$gw" dev "$iface"
          ${pkgs.iproute2}/bin/ip -6 route replace 2001:610:a38::/48 dev "$iface" 2>/dev/null || true
        '';
        type = "basic";
      }
    ];

    systemd.services.wur-eduroam-iwd-profile = {
      description = "Install WUR eduroam iwd profile";
      before = [
        "iwd.service"
        "NetworkManager.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ''
          ${pkgs.coreutils}/bin/install -m 0600 -o root -g root ${config.sops.secrets."wur/eduroam_8021x".path} /var/lib/iwd/eduroam.8021x
        '';
      };
    };
  };
}
