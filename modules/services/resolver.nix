{ config, lib, ... }:

let
  cfg = config.bresilla.services.resolver;
in
{
  options.bresilla.services.resolver = {
    enable = lib.mkEnableOption "systemd-resolved DNS resolver" // {
      default = true;
    };

    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "1.1.1.1"
        "1.0.0.1"
        "2606:4700:4700::1111"
        "2606:4700:4700::1001"
      ];
      description = "Primary DNS resolvers.";
    };

    fallbackDns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Fallback DNS resolvers.";
    };

    dnsOverTls = lib.mkOption {
      type = lib.types.oneOf [
        lib.types.bool
        (lib.types.enum [
          "opportunistic"
          "yes"
          "no"
        ])
      ];
      default = "opportunistic";
      description = "systemd-resolved DNSOverTLS setting.";
    };

    dnssec = lib.mkOption {
      type = lib.types.oneOf [
        lib.types.bool
        (lib.types.enum [
          "allow-downgrade"
          "yes"
          "no"
        ])
      ];
      default = "allow-downgrade";
      description = "systemd-resolved DNSSEC setting.";
    };

    domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Search or routing domains for systemd-resolved.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.resolved = {
      enable = true;
      settings.Resolve = {
        DNS = cfg.dns;
        FallbackDNS = cfg.fallbackDns;
        DNSOverTLS = cfg.dnsOverTls;
        DNSSEC = cfg.dnssec;
        Domains = cfg.domains;
      };
    };
  };
}
