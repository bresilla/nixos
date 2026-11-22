# The Cloudflare tunnel the public services go out through, configured only from here;
# each service adds its hostnames to `ingress`. The credentials file stays on the server.
{ config, lib, ... }:
let
  cfg = config.bresilla.server.tunnel;
in {
  options.bresilla.server.tunnel = {
    enable = lib.mkEnableOption "the Cloudflare tunnel the public services go out through";
    id = lib.mkOption { type = lib.types.str; description = "The tunnel's ID."; };
    credentials = lib.mkOption { type = lib.types.str; description = "Its credentials file, never in git."; };
    ingress = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Each public hostname and the address it goes to.";
    };
  };
  config = lib.mkIf cfg.enable {
    bresilla.server.keep.tunnel = [ cfg.credentials ];
    services.cloudflared = {
      enable = true;
      tunnels.${cfg.id} = {
        credentialsFile = cfg.credentials;
        default = "http_status:404";
        inherit (cfg) ingress;
      };
    };
  };
}
