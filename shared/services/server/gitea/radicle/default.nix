# A Radicle node beside gitea: every public repository is published on Radicle and
# kept in step with gitea, which stays the source of truth.
{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.gitea.radicle;
  gitea = config.services.gitea;
  identity = "/var/lib/radicle-identity";
  state = "/var/lib/radicle-sync";
  bot = "/var/lib/radicle-bot";
  keys = "/var/lib/radicle-keys";
  # Shows, exports or imports a user's held key: `radicle-key export bresilla`.
  keyTool = pkgs.writeShellApplication {
    name = "radicle-key";
    runtimeInputs = [ pkgs.sqlite pkgs.openssh pkgs.coreutils ];
    text = ''
      [ $# -ge 2 ] || { echo "usage: radicle-key show|export|import <gitea user> [key file]" >&2; exit 2; }
      [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad user name" >&2; exit 2; }
      uid=$(sqlite3 "file:${gitea.database.path}?mode=ro" "select id from user where lower_name = lower('$2') and type = 0")
      [ -n "$uid" ] || { echo "no such user: $2" >&2; exit 1; }
      key=${keys}/$uid/radicle
      case $1 in
        show) ssh-keygen -y -f "$key" ;;
        export) cat "$key" ;;
        import)
          [ $# -eq 3 ] || { echo "import needs a key file" >&2; exit 2; }
          ssh-keygen -y -f "$3" >/dev/null
          install -d -m 0700 -o radicle -g radicle "${keys}/$uid" "${keys}/$uid/retired"
          # The key it replaces stays, so repositories it signed can be handed over.
          if [ -s "$key" ]; then
            mv "$key" "${keys}/$uid/retired/$(date +%s)"
          fi
          install -m 0600 -o radicle -g radicle "$3" "$key"
          echo "imported; the next sync hands $2's repositories to it" ;;
        *) echo "unknown command: $1" >&2; exit 2 ;;
      esac
    '';
  };
  giteaCli = "${gitea.package}/bin/gitea --config ${gitea.customDir}/conf/app.ini";
  package = pkgs.radicle-node.overrideAttrs (previous: {
    # The CLI fixture races seed discovery and asserts the resulting status text.
    checkFlags = previous.checkFlags ++ [
      "--skip=commands::patch::rad_patch_merge_unauthorized_branch"
    ];
  });
  # rad-job writes the job COBs CI results go into; tested against the same node.
  radicleJob = pkgs.radicle-job.override { radicle-node = package; };
in {
  options.bresilla.services.gitea.radicle = {
    enable = lib.mkEnableOption "publishing public repositories on Radicle";
    alias = lib.mkOption {
      type = lib.types.str;
      description = "The node's name on the network.";
    };
    network = lib.mkOption {
      type = lib.types.enum [ "main" "test" ];
      default = "main";
      description = "Radicle network; \"test\" keeps a staging node off the public one.";
    };
    optOut = lib.mkOption {
      type = lib.types.str;
      default = "no-radicle";
      description = "Topic that keeps a public repository off Radicle.";
    };
    keys = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9._-]+");
      default = [ ];
      description = ''
        Gitea users whose Radicle key gitea holds: made once (or imported with
        `radicle-key`), it is the only delegate of their repositories and signs what
        they do in gitea. Other repositories are signed by the node's key.
      '';
    };
    organisations = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9._-]+");
      default = null;
      example = "bresilla";
      description = ''
        A user from `keys` whose key signs every organisation's repositories, as
        their only delegate. Without one, organisations are signed by the node's key.
      '';
    };
    recovery = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "did:key:z6Mk[1-9A-HJ-NP-Za-km-z]+");
      default = [ ];
      description = ''
        Offline keys added as further delegates of every repository a held key signs,
        threshold 1: any one of them can take a repository back if the held key is lost.
      '';
    };
    backup = {
      directory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/srv/gitea/backups";
        description = "Where the nightly backup goes, one folder a day beside gitea's; null for none.";
      };
      recipients = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "age recipients the private keys are encrypted to; the keys are left out without any.";
      };
    };
    bridge = {
      enable = lib.mkEnableOption ''
        issues, patches and pull requests both ways, and fast-forwards over Radicle from
        users with a held key into repositories they may write
      '';
      bot = lib.mkOption {
        type = lib.types.str;
        default = "radicle";
        description = "Gitea admin account the bridge writes and acts for users as; created with its token on first start.";
      };
      ci = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://build.bresilla.com";
        description = ''
          A muros CI whose public API the bridge reads: each run becomes a gitea commit
          status, and a Radicle job COB signed by the node for default-branch commits
          and patch revisions.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Radicle 1.x cannot protect private peer traffic: only public repositories go out.
    nixpkgs.config.permittedInsecurePackages = [ "radicle-node-1.10.3" ];

    services.radicle = {
      enable = true;
      inherit package;
      publicKey = "${identity}/radicle.pub";
      privateKey = "${identity}/radicle";
      # Outbound only: peers fetch over the connections this node opens.
      node.listenAddress = "127.0.0.1";
      settings.node = {
        inherit (cfg) alias network;
        # Only what the sync publishes is seeded, never what peers offer.
        seedingPolicy.default = "block";
      };
    };

    # The node identity, made once and kept outside the Nix store.
    systemd.services.radicle-identity = {
      description = "Radicle node identity";
      before = [ "radicle-node.service" ];
      requiredBy = [ "radicle-node.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "radicle-identity";
        StateDirectoryMode = "0700";
        UMask = "0077";
      };
      script = ''
        key=${identity}/radicle
        if [ ! -s "$key" ]; then
          rm -f "$key.new" "$key.new.pub"
          ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "" -f "$key.new"
          mv "$key.new" "$key"
          rm -f "$key.new.pub"
        fi
        ${pkgs.openssh}/bin/ssh-keygen -y -f "$key" > "$key.pub.new"
        chmod 0644 "$key.pub.new"
        mv "$key.pub.new" "$key.pub"
      '';
    };

    # Reads repositories and the database through the gitea group, writes only Radicle's storage.
    users.users.radicle.extraGroups = [ gitea.group ];

    # Users' keys: only the radicle user (and root, for `radicle-key`) can read them.
    systemd.tmpfiles.rules = [ "d ${keys} 0700 radicle radicle -" ];
    environment.systemPackages = [ keyTool ];

    systemd.services.radicle-sync = {
      description = "Publish gitea's public repositories on Radicle";
      requires = [ "radicle-node.service" ] ++ lib.optional cfg.bridge.enable "radicle-bot.service";
      after = [ "radicle-node.service" "gitea.service" ] ++ lib.optional cfg.bridge.enable "radicle-bot.service";
      path = [ package pkgs.gitMinimal pkgs.openssh pkgs.sqlite pkgs.jq pkgs.coreutils pkgs.findutils pkgs.gawk pkgs.gnugrep ]
        ++ lib.optional cfg.bridge.enable pkgs.python3
        ++ lib.optional (cfg.bridge.enable && cfg.bridge.ci != null) radicleJob;
      environment = {
        DATABASE = gitea.database.path;
        REPOSITORIES = gitea.repositoryRoot;
        RADICLE = config.services.radicle.settings.node.alias;
        RAD_STATE = "/var/lib/radicle";
        RAD_CONFIG = "${config.services.radicle.configFile}";
        SYNC_STATE = state;
        OPT_OUT = cfg.optOut;
        ORIGIN = "https://${config.bresilla.services.gitea.domain}";
        KEYS = keys;
        KEY_USERS = toString cfg.keys;
        ORG_KEY = if cfg.organisations == null then "" else cfg.organisations;
        RECOVERY = toString cfg.recovery;
      } // lib.optionalAttrs cfg.bridge.enable {
        BRIDGE = "${./bridge.py}";
        GITEA_URL = "http://127.0.0.1:3000";
        BOT = cfg.bridge.bot;
      } // lib.optionalAttrs (cfg.bridge.enable && cfg.bridge.ci != null) {
        CI_URL = cfg.bridge.ci;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "radicle";
        Group = "radicle";
        SupplementaryGroups = [ gitea.group ];
        LoadCredential = [ "key:${identity}/radicle" ] ++ lib.optional cfg.bridge.enable "token:${bot}/token";
        StateDirectory = "radicle-sync";
        StateDirectoryMode = "0755";
        RuntimeDirectory = "radicle-sync";
        RuntimeDirectoryMode = "0700";
        ReadWritePaths = [ "/var/lib/radicle" keys ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        LockPersonality = true;
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
        UMask = "0022";
      };
      script = builtins.readFile ./sync.sh;
    };
    systemd.timers.radicle-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "*:*:0/30"; AccuracySec = "1s"; };
    };

    # Nightly: storage and sync state as they are, the keys only encrypted. Root packs
    # them (the keys are root's), gitea's user writes them to the shared backup folder.
    systemd.services.radicle-backup = lib.mkIf (cfg.backup.directory != null) {
      description = "Back up Radicle's state and keys";
      path = [ pkgs.gnutar pkgs.zstd pkgs.age pkgs.age-plugin-yubikey pkgs.coreutils pkgs.findutils ];
      serviceConfig = {
        Type = "oneshot";
        User = gitea.user;
        Group = gitea.group;
        RuntimeDirectory = "radicle-backup";
        RuntimeDirectoryMode = "0700";
        ReadWritePaths = [ cfg.backup.directory ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        UMask = "0077";
        ExecStartPre = "+${pkgs.writeShellScript "radicle-backup-pack" ''
          set -euo pipefail
          export PATH=${lib.makeBinPath [ pkgs.gnutar pkgs.zstd pkgs.age pkgs.age-plugin-yubikey pkgs.coreutils ]}
          out=/run/radicle-backup
          tar -C /var/lib -cf - radicle radicle-sync | zstd -q -T0 > "$out/radicle-state.tar.zst"
          ${lib.optionalString (cfg.backup.recipients != [ ]) ''
            tar -C /var/lib -cf - radicle-identity radicle-keys | zstd -q \
              | age ${lib.concatMapStringsSep " " (r: "-r ${lib.escapeShellArg r}") cfg.backup.recipients} \
              > "$out/radicle-keys.tar.zst.age"
          ''}
          chown -R ${gitea.user}:${gitea.group} "$out"
        ''}";
      };
      script = ''
        dir=${cfg.backup.directory}/$(date +%F)
        mkdir -p "$dir"
        cp /run/radicle-backup/* "$dir/"
      '';
    };
    systemd.timers.radicle-backup = lib.mkIf (cfg.backup.directory != null) {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "*-*-* 03:30"; Persistent = true; };
    };

    # The bridge's gitea account and API token, made once and kept outside the Nix store.
    systemd.services.radicle-bot = lib.mkIf cfg.bridge.enable {
      description = "Gitea account of the Radicle bridge";
      after = [ "gitea.service" ];
      requires = [ "gitea.service" ];
      environment.GITEA_WORK_DIR = gitea.stateDir;
      path = [ pkgs.gawk pkgs.gnugrep pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = gitea.user;
        Group = gitea.group;
        StateDirectory = "radicle-bot";
        StateDirectoryMode = "0700";
        ReadWritePaths = [ gitea.stateDir (dirOf gitea.database.path) ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        LockPersonality = true;
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
        UMask = "0077";
      };
      script = ''
        token=${bot}/token
        [ -s "$token" ] && exit 0
        if ! ${giteaCli} admin user list | awk 'NR > 1 { print tolower($2) }' | grep -qxF ${lib.toLower cfg.bridge.bot}; then
          ${giteaCli} admin user create --username ${cfg.bridge.bot} --random-password --admin \
            --email ${cfg.bridge.bot}@noreply.${config.bresilla.services.gitea.domain} --must-change-password=false >/dev/null
        fi
        # Public repositories only, and only their code, issues and pull requests; as an
        # admin it may act for a user (sudo), which the bridge does only for linked ones.
        ${giteaCli} admin user generate-access-token --username ${cfg.bridge.bot} --raw \
          --token-name "radicle-bridge-$(date +%s)" --scopes public-only,write:repository,write:issue > "$token.new"
        mv "$token.new" "$token"
      '';
    };

    # The settings page's backend; gitea itself decides who may use it.
    systemd.services.radicle-settings = {
      description = "Radicle settings of gitea repositories";
      after = [ "gitea.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        DATABASE = gitea.database.path;
        SYNC_STATE = state;
        ORIGIN = "https://${config.bresilla.services.gitea.domain}";
        PORT = "3100";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./settings.py}";
        Restart = "on-failure";
        User = "radicle";
        Group = "radicle";
        SupplementaryGroups = [ gitea.group ];
        StateDirectory = "radicle-sync";
        StateDirectoryMode = "0755";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
        UMask = "0022";
      };
    };

    # Each public repository's Radicle ID, read by the clone panel; settings go to their service.
    services.caddy.virtualHosts."http://:80".extraConfig = ''
      handle /-/radicle/settings/* {
        reverse_proxy 127.0.0.1:3100
      }
      # Linked Radicle IDs per user; "@" is never part of a gitea name.
      handle_path /-/radicle/@/* {
        root * ${state}/users
        header Cache-Control "no-cache"
        try_files {path} /none.json
        file_server
      }
      handle_path /-/radicle/* {
        root * ${state}/public
        header Cache-Control "no-cache"
        # An unpublished repository answers with an empty object, not an error.
        try_files {path} /none.json
        file_server
      }
    '';
  };
}
