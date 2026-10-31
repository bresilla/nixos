# Gitea with a branded theme and a nightly backup, for a NixOS container. The host adds
# the container and its storage at /srv/gitea.
{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.gitea;
  gitea = config.services.gitea;
  # Overrides of gitea's own templates and assets, plus PNG icons from the SVG logo.
  custom = pkgs.runCommand "gitea-custom" { nativeBuildInputs = [ pkgs.librsvg ]; } ''
    cp -r ${./templates} templates
    cp -r ${./public} public
    chmod -R u+w templates public
    img=public/assets/img
    cp $img/logo.svg $img/favicon.svg
    rsvg-convert -w 512 $img/logo.svg -o $img/logo.png
    rsvg-convert -w 180 $img/logo.svg -o $img/apple-touch-icon.png
    rsvg-convert -w 64 $img/logo.svg -o $img/favicon.png
    mkdir $out && mv templates public $out/
  '';
in {
  options.bresilla.services.gitea = {
    domain = lib.mkOption {
      type = lib.types.str;
      description = "The public domain of the forge.";
    };
    appName = lib.mkOption {
      type = lib.types.str;
      description = "The name shown across the site.";
    };
    uid = lib.mkOption {
      type = lib.types.int;
      description = "Fixed gitea user, so files on shared storage keep their owner.";
    };
  };

  config = {
    systemd.tmpfiles.rules = [
      "L+ ${gitea.customDir}/templates - - - - ${custom}/templates"
      "L+ ${gitea.customDir}/public - - - - ${custom}/public"
    ];
    systemd.services.gitea.restartTriggers = [ custom ];
    system.stateVersion = "26.05";
    networking.firewall.enable = false;
    # The host's resolver listens on its own loopback, which this network can't reach.
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
    users.users.gitea.uid = cfg.uid;
    users.groups.gitea.gid = cfg.uid;
    # The unit only unlocks repos and LFS; attachments sit beside them.
    systemd.services.gitea.serviceConfig.ReadWritePaths = [ "/srv/gitea" ];
    services.gitea = {
      enable = true;
      inherit (cfg) appName;
      database.type = "sqlite3";
      repositoryRoot = "/srv/gitea/repositories";
      lfs = { enable = true; contentDir = "/srv/gitea/lfs"; };
      settings = {
        server = {
          DOMAIN = cfg.domain;
          ROOT_URL = "https://${cfg.domain}/";
          HTTP_PORT = 3000;
          START_SSH_SERVER = true;
          # Clone URLs use port 22; the host forwards it to 2222.
          SSH_DOMAIN = cfg.domain;
          SSH_PORT = 22;
          SSH_LISTEN_PORT = 2222;
        };
        service.DISABLE_REGISTRATION = true;
        # Follows the OS light/dark setting, which the logo and accent also follow.
        ui = { DEFAULT_THEME = "gitea-auto"; THEMES = "gitea-auto"; };
        attachment.PATH = "/srv/gitea/attachments";
      };
    };

    # Nightly database and secrets copy next to the repos; 14 days kept.
    systemd.services.gitea-backup = {
      serviceConfig = { Type = "oneshot"; User = gitea.user; Group = gitea.group; };
      path = [ pkgs.sqlite pkgs.gnutar pkgs.findutils pkgs.coreutils ];
      script = ''
        dir=/srv/gitea/backups/$(date +%F)
        mkdir -p "$dir"
        sqlite3 ${gitea.database.path} ".backup '$dir/gitea.db'"
        tar -C ${gitea.customDir} -cf "$dir/conf.tar" conf
        find /srv/gitea/backups -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
      '';
    };
    systemd.timers.gitea-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "03:00"; Persistent = true; };
    };
  };
}
