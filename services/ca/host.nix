# cert.bresilla.com: bresilla's own certificate authority (step-ca), for the
# services reached only inside. Like the vault it has no public name: machines find
# it through shared/system/hosts.nix, on hive's overlay address, port 8443.
# It exists once shared/system/pki holds the root and intermediate certificates,
# which make-root.sh creates with the YubiKeys; its secrets come with them.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.server.ca;
  domain = "cert.bresilla.com";
  hostAddress = "10.231.6.1";
  address = "10.231.6.2";
  port = 8443;
  overlay = { address = "100.68.233.203"; interface = "netbird0"; };
  pki = ../../shared/system/pki;
  ready = builtins.pathExists (pki + "/bresilla-root.crt")
    && builtins.pathExists (pki + "/bresilla-intermediate.crt");
in {
  options.bresilla.server.ca.enable = lib.mkEnableOption "the certificate authority, cert.bresilla.com";
  config = lib.mkIf (ready && cfg.enable) {
    bresilla.server.containers = [ "ca" ];
    networking.firewall.interfaces.${overlay.interface}.allowedTCPPorts = [ port ];
    systemd.sockets.ca-overlay = {
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "${overlay.address}:${toString port}" ];
      socketConfig.FreeBind = true;
    };
    systemd.services.ca-overlay = {
      requires = [ "container@ca.service" ];
      after = [ "container@ca.service" ];
      serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${address}:${toString port}";
    };

    networking.nat = { enable = true; internalInterfaces = [ "ve-ca" ]; externalInterface = "enp4s0"; };
    bresilla.server.containerNet.ca = { host = hostAddress; local = address; };

    containers.ca = {
      autoStart = true;
      privateUsers = 524288;
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      config = {
        imports = [ ./. ];
        bresilla.services.ca = {
          inherit domain port;
          allow = [ "*.bresilla.com" ];
          # Before signing for the vault, it checks the vault's own port.
          hosts."vault.bresilla.com" = "10.231.5.2";
          hosts."net.bresilla.com" = "10.231.7.2";
          root = pki + "/bresilla-root.crt";
          intermediate = pki + "/bresilla-intermediate.crt";
        };
      };
    };
  };
}
