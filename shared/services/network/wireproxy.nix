{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.wireproxy;
  unit = description: conf: {
    inherit description;
    documentation = [ "https://github.com/octeep/wireproxy" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.wireproxy}/bin/wireproxy -c ${conf}";
      ExecReload = "${pkgs.coreutils}/bin/kill -SIGUSR1 $MAINPID";
      Restart = "always";
      RestartSec = 5;
    };
  };
in
{
  options.bresilla.services.wireproxy.enable =
    lib.mkEnableOption "the WireGuard SOCKS5 proxy, configured by ~/.local/share/mlvd.conf";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.wireproxy ];
    systemd.user.services.wireproxy = unit "WireGuard SOCKS5 proxy" "%h/.local/share/mlvd.conf" // {
      wantedBy = [ "default.target" ];
    };
    # Started per tunnel: systemctl --user start wireproxy@<name> reads ~/.local/share/<name>.conf.
    systemd.user.services."wireproxy@" = unit "WireGuard SOCKS5 proxy (%I)" "%h/.local/share/%I.conf";
  };
}
