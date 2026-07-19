{ config, lib, ... }:

let
  cfg = config.bresilla.services.privateHosts;
  secret = config.sops.secrets."network/hosts";
in
{
  options.bresilla.services.privateHosts = {
    enable = lib.mkEnableOption "encrypted private /etc/hosts entries" // {
      # Needs the sops age key — off automatically on hosts without secrets.
      default = config.bresilla.secrets.enable;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc.hosts.mode = "0644";

    systemd.services.private-hosts = {
      description = "Install encrypted private hosts entries";
      requires = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      before = [
        "network-pre.target"
        "NetworkManager.service"
        "systemd-resolved.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        install -d -m 0755 /run/private-hosts
        tmp=/run/private-hosts/hosts

        cat ${config.environment.etc.hosts.source} > "$tmp"

        if [ -s ${secret.path} ]; then
          printf '\n# encrypted private hosts\n' >> "$tmp"
          cat ${secret.path} >> "$tmp"
        fi

        install -m 0644 -o root -g root "$tmp" /etc/hosts
      '';
    };
  };
}
