{ config, lib, pkgsUnstable, ... }:

let
  cfg = config.bresilla.services.lan-mouse;
  # lan-mouse 0.11 from unstable, built with the system libgit2 its libgit2-sys asks for.
  lan-mouse = pkgsUnstable.lan-mouse.overrideAttrs (old: {
    buildInputs = (old.buildInputs or [ ]) ++ [ pkgsUnstable.libgit2 ];
  });
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
    environment.systemPackages = [ lan-mouse ];
    # Reachable over NetBird only, never on wifi or the LAN.
    networking.firewall.interfaces.netbird0.allowedUDPPorts = [ cfg.port ];
    systemd.user.services.lan-mouse = {
      description = "Mouse and keyboard sharing";
      documentation = [ "https://github.com/feschber/lan-mouse" ];
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${lan-mouse}/bin/lan-mouse daemon";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
