{ config, lib, pkgs, bresilla, ... }:

let
  cfg = config.bresilla.services.lan-mouse;
in
{
  options.bresilla.services.lan-mouse = {
    enable = lib.mkEnableOption "lan-mouse, one mouse and keyboard across machines";
    port = lib.mkOption {
      type = lib.types.port;
      default = 4242;
      description = "UDP port, the same as `port` in ~/.config/lan-mouse/config.toml.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ bresilla.lan-mouse ];
    # Reachable over NetBird only, never on wifi or the LAN.
    networking.firewall.interfaces.netbird0.allowedUDPPorts = [ cfg.port ];
    systemd.user.services.lan-mouse = {
      description = "Mouse and keyboard sharing";
      documentation = [ "https://github.com/feschber/lan-mouse" ];
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${bresilla.lan-mouse}/bin/lan-mouse daemon";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
