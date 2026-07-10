{ lib, ... }:

{
  bresilla.features.network.wireNames.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "server";
  bresilla.features.system.ssh.enable = lib.mkDefault true;
  services.fail2ban.enable = lib.mkDefault true;
}
