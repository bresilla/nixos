{ lib, ... }:

{
  bresilla.features.network.wireNames.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "server";
  bresilla.system.remote.ssh.enable = lib.mkDefault true;
}
