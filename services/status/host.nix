# status.bresilla.com on hive: what failed and what is fine, on hive and nest. Only the
# overlay reaches it (overlay.nix), signed in through id.bresilla.com. Every five
# minutes hive writes its own report and takes nest's over the direct link; the
# container only reads the two.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.server.status;
  domain = "status.bresilla.com";
  hostAddress = "10.231.8.1";
  address = "10.231.8.2";
  reports = "/var/lib/status";
  pki = ../../shared/system/pki;
  caReady = builtins.pathExists (pki + "/bresilla-root.crt");
  collect = pkgs.writeShellApplication {
    name = "status-collect";
    runtimeInputs = with pkgs; [ systemd jq coreutils util-linux openssl findutils gawk gnused btrfs-progs smartmontools ];
    text = builtins.readFile ./collect.sh;
  };
  # Each site as it is served: the overlay's from their containers, the rest from outside.
  certs = [
    "vault.bresilla.com=10.231.5.2:443"
    "cert.bresilla.com=10.231.6.2:8443"
    "net.bresilla.com=10.231.7.2:443"
    "${domain}=${address}:443"
    "id.bresilla.com=id.bresilla.com:443"
    "git.bresilla.com=git.bresilla.com:443"
    "cache.bresilla.com=cache.bresilla.com:443"
    "build.bresilla.com=build.bresilla.com:443"
    "s3.bresilla.com=s3.bresilla.com:443"
  ];
  roots = [ "bresilla-root=${pki}/bresilla-root.crt" "bresilla-intermediate=${pki}/bresilla-intermediate.crt" ];
in {
  options.bresilla.server.status.enable = lib.mkEnableOption "the status page, status.bresilla.com";
  config = lib.mkIf cfg.enable {
    bresilla.server.containers = [ "status" ];
    bresilla.server.overlay.sites.${domain} = "${address}:443";
    networking.nat = { enable = true; internalInterfaces = [ "ve-status" ]; externalInterface = "enp4s0"; };
    bresilla.server.containerNet.status = { host = hostAddress; local = address; };
    systemd.tmpfiles.rules = [ "d ${reports} 0755 root root -" ];

    systemd.services.status-collect = {
      description = "Write hive's report and fetch nest's, for ${domain}";
      serviceConfig = { Type = "oneshot"; Nice = 10; TimeoutStartSec = "3min"; };
      environment = {
        CERTS = toString certs;
        ROOTS = lib.optionalString caReady (toString roots);
      };
      path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
      script = ''
        install -d -m 0755 ${reports}
        ${lib.getExe collect} ${reports}/hive.json failed containers timers certs
        # Nest's report is taken only when it is whole; an old one shows its age on the page.
        if curl -sf --max-time 10 http://nest.link:9101/nest.json -o ${reports}/nest.new && jq -e .at ${reports}/nest.new > /dev/null; then
          chmod 0644 ${reports}/nest.new && mv ${reports}/nest.new ${reports}/nest.json
        fi
        rm -f ${reports}/nest.new
      '';
    };
    systemd.timers.status-collect = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "5min"; };
    };

    containers.status = {
      autoStart = true;
      privateUsers = 524288;
      extraFlags = [ "--private-users-ownership=auto" ];
      privateNetwork = true;
      bindMounts.${reports} = { hostPath = reports; isReadOnly = true; };
      config = {
        imports = [ ./. ];
        bresilla.services.status = {
          inherit domain;
          login = {
            issuer = "https://id.bresilla.com/oauth2/openid/status";
            client = "status";
            envFile = "/var/lib/oidc/proxy.env";
          };
          ca = lib.mkIf caReady {
            name = "cert.bresilla.com";
            address = "10.231.6.2";
            directory = "https://cert.bresilla.com:8443/acme/acme/directory";
            root = pki + "/bresilla-root.crt";
          };
        };
      };
    };
  };
}
