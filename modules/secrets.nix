{ config, lib, ... }:

let
  hostSecrets = ../secrets/hosts/${config.networking.hostName}.yaml;
  commonHosts = ../secrets/common/hosts;
in
{
  sops = {
    defaultSopsFile = hostSecrets;
    age = {
      keyFile = "/var/lib/sops-nix/key.txt";
      sshKeyPaths = [ ];
    };
    secrets = {
      "netbird/setup_key" = { };
      "wireguard/private_key" = { };
      "wifi/home_psk" = { };
      "network/hosts" = {
        sopsFile = commonHosts;
        format = "binary";
      };
      "wur/access_creds" = { };
      "wur/access_pem" = { };
      "wur/eduroam_8021x" = { };
      "zerotier/devicemap" = { };
    };
  };

  assertions = [
    {
      assertion = builtins.pathExists hostSecrets;
      message = "Missing encrypted sops secrets file for host ${config.networking.hostName}: ${toString hostSecrets}";
    }
    {
      assertion = builtins.pathExists commonHosts;
      message = "Missing encrypted common hosts sops secret: ${toString commonHosts}";
    }
  ];
}
