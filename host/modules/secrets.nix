{ config, lib, ... }:

let
  systemSecrets = ../secrets/system.yaml;
  commonHosts = ../secrets/common/hosts;
  commonGithub = ../secrets/common/github.yaml;
in
{
  sops = {
    defaultSopsFile = systemSecrets;
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
      "github/token" = {
        sopsFile = commonGithub;
        owner = config.bresilla.user.name;
        mode = "0400";
      };
      "wur/access_creds" = { };
      "wur/access_pem" = { };
      "wur/eduroam_8021x" = { };
    };
  };

  assertions = [
    {
      assertion = builtins.pathExists systemSecrets;
      message = "Missing encrypted shared system sops secret: ${toString systemSecrets}";
    }
    {
      assertion = builtins.pathExists commonHosts;
      message = "Missing encrypted common hosts sops secret: ${toString commonHosts}";
    }
    {
      assertion = builtins.pathExists commonGithub;
      message = "Missing encrypted common GitHub token sops secret: ${toString commonGithub}";
    }
  ];
}
