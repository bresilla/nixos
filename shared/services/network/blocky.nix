{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.blocky;
  user = config.bresilla.user.name;
in
{
  options.bresilla.services.blocky = {
    enable = lib.mkEnableOption "the Blocky DNS proxy";
    configFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.users.users.${user}.home}/.config/blocky/config.yaml";
      description = "Blocky configuration. Its DNS port must not clash with systemd-resolved on 127.0.0.53.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.blocky ];
    systemd.services.blocky = {
      description = "Blocky DNS proxy";
      documentation = [ "https://github.com/0xERR0R/blocky" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = user;
        ExecStart = "${pkgs.blocky}/bin/blocky --config ${cfg.configFile}";
        ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR1 $MAINPID";
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        NoNewPrivileges = true;
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
