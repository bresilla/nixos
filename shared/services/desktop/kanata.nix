{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.kanata;
  user = config.bresilla.user.name;
in
{
  options.bresilla.services.kanata = {
    enable = lib.mkEnableOption "the Kanata keyboard remapper";
    configFile = lib.mkOption {
      type = lib.types.str;
      default = "%h/.config/kanata/minial.kbd";
      description = "Kanata configuration the user service loads.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Kanata reads keyboards and writes a virtual one as the user.
    hardware.uinput.enable = true;
    users.users.${user}.extraGroups = [ "input" "uinput" ];
    environment.systemPackages = [ pkgs.kanata ];
    systemd.user.services.kanata = {
      description = "Kanata keyboard remapper";
      documentation = [ "https://github.com/jtroo/kanata" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.kanata}/bin/kanata --cfg ${cfg.configFile}";
        Restart = "no";
      };
    };
  };
}
