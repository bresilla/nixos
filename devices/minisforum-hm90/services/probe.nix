# Throwaway container that tries out a container setup before gitea or cache get it.
{ pkgs, ... }:
{
  hive.containerNet.probe = { host = "10.231.9.1"; local = "10.231.9.2"; };
  networking.nat = { enable = true; internalInterfaces = [ "ve-probe" ]; externalInterface = "enp4s0"; };

  containers.probe = {
    autoStart = true;
    privateUsers = 524288;
    extraFlags = [ "--private-users-ownership=auto" ];
    privateNetwork = true;
    config = {
      system.stateVersion = "26.05";
      networking.firewall.enable = false;
      networking.useHostResolvConf = false;
      networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
      environment.systemPackages = [ pkgs.perl ];
    };
  };
}
