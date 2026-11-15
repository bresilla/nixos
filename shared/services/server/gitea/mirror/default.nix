# Mirrors of gitea's public repositories on other git hosts, over SSH with a key
# held by an agent outside the container. Gitea stays the source of truth and never
# waits on any of this: no hooks, only a timer that reads its database and pushes
# to it like any user.
{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.gitea.mirror;
  gitea = config.services.gitea;
  configDir = "/var/lib/git-mirror-config";
  state = "/var/lib/git-mirror";
  bot = "/var/lib/git-mirror-bot";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./common.py ./mirror.py ./settings.py ];
  };
  knownHosts = pkgs.writeText "git-mirror-known-hosts" (lib.concatLines cfg.knownHosts);
  giteaCli = "${gitea.package}/bin/gitea --config ${gitea.customDir}/conf/app.ini";
  common = {
    DATABASE = gitea.database.path;
    MIRROR_CONFIG = configDir;
    MIRROR_STATE = state;
    KNOWN_HOSTS = "${knownHosts}";
  };
  confined = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    CapabilityBoundingSet = "";
    SystemCallArchitectures = "native";
  };
  # The sync and the probes: the only units with the agent's socket.
  runner = what: {
    description = if what == "sync" then "Mirror gitea repositories" else "Check mirror targets for the settings page";
    after = [ "gitea.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    # Started by the timer and by every click on the page, often within seconds.
    unitConfig.StartLimitIntervalSec = 0;
    path = [ pkgs.gitMinimal pkgs.openssh ];
    environment = common // {
      REPOSITORIES = gitea.repositoryRoot;
      GITEA = "http://127.0.0.1:3000";
      BOT = cfg.bot;
      SSH_AUTH_SOCK = cfg.agentSocket;
    };
    serviceConfig = confined // {
      Type = "oneshot";
      User = "git-mirror";
      Group = "git-mirror";
      SupplementaryGroups = [ gitea.group "git-mirror-agent" ];
      ExecStart = "${pkgs.python3}/bin/python3 ${src}/mirror.py ${what}";
      LoadCredential = lib.optional (what == "sync") "token:${bot}/token";
      StateDirectory = "git-mirror";
      StateDirectoryMode = "0755";
      RuntimeDirectory = "git-mirror-${what}";
      RuntimeDirectoryMode = "0700";
      ReadWritePaths = [ configDir ];
      TimeoutStartSec = "1h";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      UMask = "0002";
    };
  };
in {
  options.bresilla.services.gitea.mirror = {
    enable = lib.mkEnableOption "mirroring public repositories to and from other git hosts";
    agentSocket = lib.mkOption {
      type = lib.types.str;
      default = "/run/git-mirror-agent/agent.sock";
      description = "The SSH agent holding the mirror's key, bound in from the host.";
    };
    uid = lib.mkOption {
      type = lib.types.int;
      default = 3010;
      description = "The mirror's user; the agent group is uid + 1, the page's user uid + 2.";
    };
    bot = lib.mkOption {
      type = lib.types.str;
      default = "git-mirror";
      description = "Gitea admin account that pushes what comes from remotes; made with its token on first start.";
    };
    knownHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # From https://api.github.com/meta, checked against GitHub's published fingerprints.
      default = [
        "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        "github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg="
        "github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk="
      ];
      description = ''
        Pinned host keys (known_hosts lines). Site admins may trust other hosts' keys
        from the settings page; hosts named here keep only these.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    bresilla.services.gitea.footers = [ ./footer.tmpl ];

    users.users.git-mirror = { uid = cfg.uid; group = "git-mirror"; isSystemUser = true; };
    users.groups.git-mirror.gid = cfg.uid;
    # Only the mirror may talk to the agent: the socket's group on the host.
    users.groups.git-mirror-agent.gid = cfg.uid + 1;
    users.users.git-mirror-ui = { uid = cfg.uid + 2; group = "git-mirror"; isSystemUser = true; };

    # The page's user writes links and namespaces, the mirror reads them and writes
    # back only auto-links and the queue it empties.
    systemd.tmpfiles.rules = [
      "d ${configDir} 2770 git-mirror-ui git-mirror -"
      "d ${configDir}/links 2770 git-mirror-ui git-mirror -"
      "d ${configDir}/owners 2770 git-mirror-ui git-mirror -"
      "d ${configDir}/spool 2770 git-mirror-ui git-mirror -"
      "d ${configDir}/spool/probe 2770 git-mirror-ui git-mirror -"
      "d ${configDir}/spool/sync 2770 git-mirror-ui git-mirror -"
    ];

    systemd.services.git-mirror = runner "sync" // {
      requires = [ "git-mirror-bot.service" ];
      after = [ "gitea.service" "network-online.target" "git-mirror-bot.service" ];
    };
    systemd.services.git-mirror-probe = runner "probe";
    systemd.timers.git-mirror = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "*:*:0/30"; AccuracySec = "1s"; };
    };
    # "Sync now" and URL checks from the page start their unit at once.
    systemd.paths.git-mirror = {
      wantedBy = [ "paths.target" ];
      pathConfig.DirectoryNotEmpty = "${configDir}/spool/sync";
    };
    systemd.paths.git-mirror-probe = {
      wantedBy = [ "paths.target" ];
      pathConfig.DirectoryNotEmpty = "${configDir}/spool/probe";
    };

    # The bot's gitea account and token, made once and kept outside the Nix store.
    systemd.services.git-mirror-bot = {
      description = "Gitea account of the git mirror";
      after = [ "gitea.service" ];
      requires = [ "gitea.service" ];
      environment.GITEA_WORK_DIR = gitea.stateDir;
      path = [ pkgs.gawk pkgs.gnugrep pkgs.coreutils ];
      serviceConfig = confined // {
        Type = "oneshot";
        RemainAfterExit = true;
        User = gitea.user;
        Group = gitea.group;
        StateDirectory = "git-mirror-bot";
        StateDirectoryMode = "0700";
        ReadWritePaths = [ gitea.stateDir (dirOf gitea.database.path) ];
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        UMask = "0077";
      };
      script = ''
        token=${bot}/token
        [ -s "$token" ] && exit 0
        if ! ${giteaCli} admin user list | awk 'NR > 1 { print tolower($2) }' | grep -qxF ${lib.toLower cfg.bot}; then
          ${giteaCli} admin user create --username ${cfg.bot} --random-password --admin \
            --email ${cfg.bot}@noreply.${lib.head (lib.splitString ":" config.bresilla.services.gitea.domain)} --must-change-password=false >/dev/null
        fi
        # Public repositories only, and only their code.
        ${giteaCli} admin user generate-access-token --username ${cfg.bot} --raw \
          --token-name "git-mirror-$(date +%s)" --scopes public-only,write:repository > "$token.new"
        mv "$token.new" "$token"
      '';
    };

    # The settings pages' backend: no key, no network but gitea's loopback.
    systemd.services.git-mirror-settings = {
      description = "Mirror settings of gitea repositories and owners";
      after = [ "gitea.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = common // {
        ORIGIN = "https://${config.bresilla.services.gitea.domain}";
        PORT = "3101";
      };
      serviceConfig = confined // {
        ExecStart = "${pkgs.python3}/bin/python3 ${src}/settings.py";
        Restart = "on-failure";
        User = "git-mirror-ui";
        Group = "git-mirror";
        SupplementaryGroups = [ gitea.group ];
        ReadWritePaths = [ configDir ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        MemoryDenyWriteExecute = true;
        UMask = "0002";
      };
    };

    services.caddy.virtualHosts."http://:80".extraConfig = ''
      handle /-/mirror/settings/* {
        reverse_proxy 127.0.0.1:3101
      }
      # Each public repository's mirrors, for the label beside its name.
      handle_path /-/mirror/* {
        root * ${state}/public
        header Cache-Control "no-cache"
        try_files {path} /none.json
        file_server
      }
    '';
  };
}
