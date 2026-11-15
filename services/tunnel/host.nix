{ config, lib, ... }:
let
  cfg = config.bresilla.server.tunnel;
in {
  options.bresilla.server.tunnel.enable = lib.mkEnableOption "the Cloudflare tunnel the public services go out through";
  config = lib.mkIf cfg.enable {
    bresilla.server.keep.tunnel = [ "/var/lib/cloudflared-hive-nix.json" ];
    # Cloudflare tunnel "hive-nix", configured only from here; each service adds its own hostnames to ingress.
    # The credentials file is a secret kept only on hive, never in git.
    services.cloudflared = {
      enable = true;
      tunnels."12c748bd-aa30-49a8-a0d4-2bb7f21267de" = {
        credentialsFile = "/var/lib/cloudflared-hive-nix.json";
        default = "http_status:404";
      };
    };
  };
}
