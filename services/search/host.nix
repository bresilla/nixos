# search.bresilla.com on hive: searx and its page, out through the Cloudflare tunnel and
# only after signing in at id.bresilla.com. The container keeps only its signing key.
{ config, lib, bresilla, ... }:
let
  cfg = config.bresilla.server.search;
  domain = "search.bresilla.com";
  hostAddress = "10.231.10.1";
  address = "10.231.10.2";
in {
  options.bresilla.server.search.enable = lib.mkEnableOption "web search, search.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "search" ];
    bresilla.server.tunnel.ingress.${domain} = "http://${address}:8080";
    # Outbound only (the search providers); nothing outside hive opens a connection to it.
    networking.nat = { enable = true; internalInterfaces = [ "ve-search" ]; };
    bresilla.server.containerNet.search = { host = hostAddress; local = address; };

    containers.search = {
      autoStart = true;
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      config = {
        imports = [ ./. ];
        bresilla.services.search = {
          inherit domain;
          searx = bresilla.searx;
          login = {
            issuer = "https://id.bresilla.com/oauth2/openid/search";
            client = "search";
            envFile = "/var/lib/oidc/proxy.env";
          };
        };
      };
    };
  };
}
