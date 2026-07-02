{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.vpnClients;
in
{
  options.bresilla.services.vpnClients = {
    mullvad = {
      enable = lib.mkEnableOption "Mullvad VPN runtime support";
      autostart = lib.mkEnableOption "Mullvad VPN daemon boot autostart";
      gui.enable = lib.mkEnableOption "Mullvad VPN GUI package";
      excludeWrapper.enable = lib.mkEnableOption "mullvad-exclude setuid wrapper";
    };
  };

  config = lib.mkIf cfg.mullvad.enable {
    services.mullvad-vpn = {
      enable = true;
      package = if cfg.mullvad.gui.enable then pkgs.mullvad-vpn else pkgs.mullvad;
      enableEarlyBootBlocking = false;
      enableExcludeWrapper = cfg.mullvad.excludeWrapper.enable;
    };

    systemd.services.mullvad-daemon.wantedBy =
      lib.mkIf (!cfg.mullvad.autostart) (lib.mkForce [ ]);
  };
}
