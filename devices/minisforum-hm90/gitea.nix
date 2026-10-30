let
  # Fixed so files on nest keep the same owner across rebuilds.
  uid = 3000;
in {
  # Repos, LFS and attachments live on nest; the database stays on hive's mirror.
  fileSystems."/mnt/nest/gitea" = {
    device = "nest.link:/data/gitea";
    fsType = "nfs4";
    options = [ "_netdev" "nofail" "noatime" ];
  };

  # Shares hive's network; the host firewall admits it only on NetBird.
  containers.gitea = {
    autoStart = true;
    bindMounts."/srv/gitea" = { hostPath = "/mnt/nest/gitea"; isReadOnly = false; };
    config = { config, pkgs, ... }: let
      gitea = config.services.gitea;
    in {
      system.stateVersion = "26.05";
      networking.firewall.enable = false;
      users.users.gitea.uid = uid;
      users.groups.gitea.gid = uid;
      # The unit only unlocks repos and LFS; attachments sit beside them.
      systemd.services.gitea.serviceConfig.ReadWritePaths = [ "/srv/gitea" ];
      services.gitea = {
        enable = true;
        database.type = "sqlite3";
        repositoryRoot = "/srv/gitea/repositories";
        lfs = { enable = true; contentDir = "/srv/gitea/lfs"; };
        settings = {
          server = {
            DOMAIN = "hive.netbird";
            ROOT_URL = "http://hive.netbird:3000/";
            HTTP_PORT = 3000;
            START_SSH_SERVER = true;
            SSH_PORT = 2222;
            SSH_LISTEN_PORT = 2222;
          };
          service.DISABLE_REGISTRATION = true;
          attachment.PATH = "/srv/gitea/attachments";
        };
      };

      # Nightly database and secrets copy onto nest, next to the repos; 14 days kept.
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
  };
}
