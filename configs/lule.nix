{ config, pkgs, ... }:

let
  script = "${config.xdg.configHome}/lule/wallpaper.sh";
in
{
  # A new Lule wallpaper, and colors from it; the laptop profile runs it on a timer.
  systemd.user.services.lule-wallpaper = {
    Unit = {
      Description = "Generate and apply a new Lule wallpaper";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${script} generate";
    };
  };
}
