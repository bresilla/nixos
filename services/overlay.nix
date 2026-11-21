# The sites reached only over the overlay share its port 443: a socket on hive's overlay
# address hands each connection to a local nginx, which passes it on by the name the
# browser asked for (TLS SNI) without decrypting it. Each container keeps its own cert.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.server.overlay;
  router = "127.0.0.1:4443";
in {
  options.bresilla.server.overlay = {
    address = lib.mkOption { type = lib.types.str; default = "100.68.233.203"; description = "hive's overlay address."; };
    interface = lib.mkOption { type = lib.types.str; default = "netbird0"; };
    sites = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Each site's name and the container address:port its TLS goes to.";
    };
  };
  config = lib.mkIf (cfg.sites != { }) {
    networking.firewall.interfaces.${cfg.interface}.allowedTCPPorts = [ 443 ];
    systemd.sockets.overlay-https = {
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "${cfg.address}:443" ];
      socketConfig.FreeBind = true;
    };
    systemd.services.overlay-https = {
      requires = [ "nginx.service" ];
      after = [ "nginx.service" ];
      serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${router}";
    };
    services.nginx = {
      enable = true;
      streamConfig = ''
        map $ssl_preread_server_name $overlay_site {
          ${lib.concatStrings (lib.mapAttrsToList (name: to: "${name} ${to};\n") cfg.sites)}
          default 127.0.0.1:1;
        }
        server {
          listen ${router};
          ssl_preread on;
          proxy_pass $overlay_site;
        }
      '';
    };
  };
}
