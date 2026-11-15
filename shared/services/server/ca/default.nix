# step-ca, as cert.bresilla.com: bresilla's own certificate authority, so services
# reached only inside get certificates with nothing outside involved. The root key
# stays on the YubiKeys (make-root.sh); this holds only the intermediate, which
# signs short-lived certificates over ACME, and only for names under the domain.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.ca;
  secrets = "/var/lib/step-ca-secrets";
in
{
  options.bresilla.services.ca = {
    domain = lib.mkOption { type = lib.types.str; description = "The CA's own name."; };
    port = lib.mkOption { type = lib.types.port; default = 8443; };
    allow = lib.mkOption { type = lib.types.listOf lib.types.str; description = "Names it may sign for."; };
    hosts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Services it checks before signing, by name, and their addresses.";
    };
    root = lib.mkOption { type = lib.types.path; description = "The root's certificate."; };
    intermediate = lib.mkOption { type = lib.types.path; description = "The intermediate's certificate."; };
  };

  config = {
    system.stateVersion = "26.05";
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
    # ACME checks reach the services here, not through any public name.
    networking.hosts = lib.mapAttrs' (name: address: lib.nameValuePair address [ name ]) cfg.hosts;

    services.step-ca = {
      enable = true;
      address = "0.0.0.0";
      inherit (cfg) port;
      intermediatePasswordFile = "${secrets}/password";
      settings = {
        root = "${cfg.root}";
        crt = "${cfg.intermediate}";
        # Read through systemd's credentials, so step-ca's throwaway user can.
        key = "/run/credentials/step-ca.service/intermediate_key";
        dnsNames = [ cfg.domain ];
        logger.format = "text";
        db = { type = "badgerv2"; dataSource = "/var/lib/step-ca/db"; };
        authority = {
          policy.x509.allow.dns = cfg.allow;
          provisioners = [{
            type = "ACME";
            name = "acme";
            challenges = [ "tls-alpn-01" ];
            claims = { defaultTLSCertDuration = "24h"; maxTLSCertDuration = "168h"; };
          }];
        };
        tls = {
          cipherSuites = [ "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256" "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256" ];
          minVersion = 1.2;
          maxVersion = 1.3;
        };
      };
    };
    # Until make-root.sh has put the intermediate key here, it waits instead of failing.
    systemd.services.step-ca = {
      unitConfig.ConditionPathExists = [ "${secrets}/intermediate_key" "${secrets}/password" ];
      serviceConfig.LoadCredential = lib.mkForce [
        "intermediate_password:${secrets}/password"
        "intermediate_key:${secrets}/intermediate_key"
      ];
    };
  };
}
