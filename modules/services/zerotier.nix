{ config, lib, ... }:

let
  cfg = config.bresilla.services.zerotier;
in
{
  options.bresilla.services.zerotier = {
    enable = lib.mkEnableOption "ZeroTier mesh VPN";
    trustedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "zerotier0"
        "zerotier1"
      ];
      description = "ZeroTier interface names trusted by the local firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.zerotierone.enable = true;
    networking.firewall.trustedInterfaces = cfg.trustedInterfaces;

    systemd.services.zerotierone.preStart = lib.mkAfter ''
      devicemap_secret="${config.sops.secrets."zerotier/devicemap".path}"
      devicemap_target=/var/lib/zerotier-one/devicemap

      if [ -s "$devicemap_secret" ]; then
        install -m 0600 -o root -g root "$devicemap_secret" "$devicemap_target"

        while IFS='=' read -r network_id interface_name; do
          case "$network_id" in
            ""|\#*) continue ;;
          esac
          touch "/var/lib/zerotier-one/networks.d/$network_id.conf"
        done < "$devicemap_target"
      fi
    '';
  };
}
