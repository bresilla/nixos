{ config, lib, ... }:

let
  modules = config.bresilla.server.kernelModules;
in
{
  options.bresilla.server.kernelModules = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = "The machine's own module list (lsmod); all load at boot and none may load later.";
  };

  config = lib.mkMerge [
    {
      bresilla.features.network.wireNames.enable = lib.mkDefault true;
      bresilla.services.netbird.routingFeatures = lib.mkDefault "server";
      bresilla.system.remote.ssh.enable = lib.mkDefault true;
      boot.swraid.mdadmConf = lib.mkDefault "MAILADDR root";
    }
    # Loaded up front so containers and firewall reloads still find theirs; add to the
    # list for new needs.
    (lib.mkIf (modules != null) {
      security.lockKernelModules = true;
      boot.kernelModules = lib.filter (m: m != "") (lib.splitString "\n" (builtins.readFile modules));
    })
  ];
}
