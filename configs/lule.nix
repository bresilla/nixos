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
      # Only spare CPU and disk, so the 4K render never competes with the desktop.
      Nice = 19;
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass = "idle";
    };
  };
}
