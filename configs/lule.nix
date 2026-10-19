{ config, pkgs, ... }:

let
  script = "${config.xdg.configHome}/lule/wallpaper.sh";
in
{
  # A new Lule wallpaper, and colors from it, every three minutes of the graphical session.
  systemd.user.services.lule-wallpaper = {
    Unit = {
      Description = "Generate and apply a new Lule wallpaper";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${script} generate";
      # New terminals take the colors from lule's sequences file; open ones are left alone.
      Environment = [ "LULE_QUIET_TTYS=1" ];
    };
  };

  systemd.user.timers.lule-wallpaper = {
    Unit = {
      Description = "New Lule wallpaper every three minutes";
      PartOf = [ "graphical-session.target" ];
    };
    Timer = {
      OnActiveSec = "3min";
      OnUnitActiveSec = "3min";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
