{ config, lib, pkgs, termworks, ... }:
let
  user = config.bresilla.user.name;
  userHome = config.users.users.${user}.home;
  directory = "/var/lib/morf/wallpaper/${user}";
  lule = termworks.lule.packages.${pkgs.stdenv.hostPlatform.system}.default;
  bridge = pkgs.writeShellScriptBin "morf-wallpaper" ''
    exec ${pkgs.python3}/bin/python3 ${./morf-wallpaper.py} "$@"
  '';
  # A minimal greeter-only palette config: user hooks belong to their session.
  luleConfig = pkgs.writeTextDir "init.lua" ''
    local lule = require("lule")
    lule.theme = "dark"
    lule.palette = "pigment"
  '';
  fallbackLogo = pkgs.writeText "morf-wallpaper-logo.svg" ''
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
      <path fill="#ffffff" d="M15 75V25h14l21 25 21-25h14v50H70V48L50 71 30 48v27z"/>
    </svg>
  '';
in {
  config = lib.mkIf config.bresilla.features.desktop.enable {
    environment.systemPackages = [ bridge ];
    system.build.morfWallpaper = bridge;
    environment.etc."morf/wallpaper.json".text = builtins.toJSON {
      inherit user directory;
      logo = "${userHome}/.dot/.bresilla/logo.svg";
      fallback_logo = toString fallbackLogo;
      lule = "${lule}/bin/lule";
      lule_config = toString luleConfig;
      command = "${bridge}/bin/morf-wallpaper";
    };
    users.groups.morf-wallpaper.members = [ user "greeter" ];
    systemd.tmpfiles.rules = [
      "d /var/lib/morf 0755 root root -"
      "d /var/lib/morf/wallpaper 0755 root root -"
      "d ${directory} 2770 ${user} morf-wallpaper -"
      "f ${directory}/.lock 0666 ${user} morf-wallpaper -"
    ];
    systemd.services.morf-wallpaper-logo = {
      description = "Share the wallpaper logo with the greeter";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" "home-manager-${user}.service" ];
      before = [ "morf-wallpaper-boot.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        ExecStart = "${bridge}/bin/morf-wallpaper logo";
        RemainAfterExit = true;
      };
    };
    systemd.services.morf-wallpaper-boot = {
      description = "Generate the shared Lule wallpaper once per boot";
      wantedBy = [ "multi-user.target" ];
      wants = [ "morf-wallpaper-logo.service" ];
      after = [ "systemd-tmpfiles-setup.service" "morf-wallpaper-logo.service" ];
      before = [ "greetd.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "greeter";
        ExecStart = "${bridge}/bin/morf-wallpaper greet";
        RemainAfterExit = true;
        TimeoutStartSec = 250;
      };
    };
    systemd.user.services.morf.serviceConfig = {
      ExecStartPre = "-${bridge}/bin/morf-wallpaper adopt";
      ExecStopPost = "-${bridge}/bin/morf-wallpaper publish";
    };
  };
}
