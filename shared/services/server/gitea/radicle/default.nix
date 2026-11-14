# A Radicle node beside gitea: every public repository is published on Radicle and
# kept in step with gitea, which stays the source of truth.
{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.gitea.radicle;
  gitea = config.services.gitea;
  identity = "/var/lib/radicle-identity";
  state = "/var/lib/radicle-sync";
  bot = "/var/lib/radicle-bot";
  userHomes = "/var/lib/radicle-users";
  json = pkgs.formats.json { };
  # A node's key: imported from a file when one is given and differs (the key it
  # replaces goes to retired/, the node's record of its old key is dropped), made
  # once otherwise; its public half beside it.
  keyInstall = pkgs.writeShellScript "radicle-key-install" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.openssh pkgs.coreutils ]}
    key=$1 home=$2 from=''${3:-}
    pub() { ssh-keygen -y -f "$1" | cut -d' ' -f1,2; }
    if [ -n "$from" ] && [ ! -s "$from" ]; then
      echo "warning: $from is missing, the node keeps its key" >&2
    elif [ -n "$from" ] && { [ ! -s "$key" ] || [ "$(pub "$from")" != "$(pub "$key")" ]; }; then
      if [ -s "$key" ]; then
        mkdir -p "$(dirname "$key")/retired"
        mv "$key" "$(dirname "$key")/retired/$(date +%s)"
      fi
      install -m 0600 "$from" "$key"
      rm -f "$home/node/fingerprint"
      echo "node key imported from $from"
    fi
    if [ ! -s "$key" ]; then
      rm -f "$key.new" "$key.new.pub"
      ssh-keygen -q -t ed25519 -N "" -C "" -f "$key.new"
      mv "$key.new" "$key"
      rm -f "$key.new.pub"
    fi
    pub "$key" > "$key.pub.new"
    chmod 0644 "$key.pub.new"
    mv "$key.pub.new" "$key.pub"
  '';
  # The main node's settings, under the user's name.
  userConfig = name: json.generate "radicle-${name}.json"
    (lib.recursiveUpdate config.services.radicle.settings { node.alias = name; });
  # Who has a node: the main one first, then each user's, for the sync and the bridge.
  nodes = json.generate "radicle-nodes.json" ([ { user = cfg.user; home = ""; recovery = cfg.recovery; } ]
    ++ lib.mapAttrsToList (name: u: { user = name; home = "${userHomes}/${name}"; inherit (u) recovery; }) cfg.users);
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
    hideNodes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Node IDs left out of the seed lists: retired or throwaway nodes the network still remembers.";
    };
    optOut = lib.mkOption {
      type = lib.types.str;
      default = "no-radicle";
      description = "Topic that keeps a public repository off Radicle.";
    };
    user = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9._-]+";
      default = cfg.alias;
      defaultText = lib.literalExpression "alias";
      description = ''
        Gitea user whose key the node is: it signs their repositories, those of the
        organisations they own and what they do in gitea.
      '';
    };
    identityFrom = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/keys/radicle";
      description = ''
        A private key file the node takes as its key when it differs from the current
        one, which is kept in retired/; without one the key is made once.
      '';
    };
    recovery = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "did:key:z6Mk[1-9A-HJ-NP-Za-km-z]+");
      default = [ ];
      description = ''
        Offline keys added as further delegates of the node's repositories, threshold 1
        for branches. Identity revisions need a majority of the delegates, so with one
        every rename, description or default branch change waits for its vote
        (`rad id accept`), and it cannot take a repository over alone either.
      '';
    };
    users = lib.mkOption {
      default = { };
      example = lib.literalExpression ''{ alice = { }; }'';
      description = ''
        Other gitea users, each with a node of their own (`radicle-node@<user>`,
        outbound only) that signs their repositories and what they do in gitea.
        Users without one are not published.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          identityFrom = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "As the node's own `identityFrom`, for this user's node.";
          };
          recovery = lib.mkOption {
            type = lib.types.listOf (lib.types.strMatching "did:key:z6Mk[1-9A-HJ-NP-Za-km-z]+");
            default = [ ];
            description = "Offline keys added as delegates of this user's repositories.";
          };
        };
      });
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
      enable = lib.mkEnableOption "issues, patches and pull requests both ways";
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

  config = lib.mkIf cfg.enable (lib.mkMerge [ {
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

    # The node's key, kept outside the Nix store; restarting this restarts the node.
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
        ExecStart = "${keyInstall} ${identity}/radicle /var/lib/radicle ${lib.optionalString (cfg.identityFrom != null) (lib.escapeShellArg cfg.identityFrom)}";
      };
    };

    # Reads repositories and the database through the gitea group, writes only Radicle's storage.
    users.users.radicle.extraGroups = [ gitea.group ];

    systemd.tmpfiles.rules = [ "d ${userHomes} 0700 radicle radicle -" ];
  }
  {
    # One node per user with a key of their own: own storage, outbound only, the main
    # node's seeds; the sync and the bridge use its home as theirs for that user.
    systemd.services = lib.mapAttrs' (name: u: lib.nameValuePair "radicle-node@${name}" {
      description = "Radicle node of ${name}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Started with each sync too; one that is down fails only its user's repositories.
      before = [ "radicle-sync.service" ];
      wantedBy = [ "multi-user.target" "radicle-sync.service" ];
      environment = { RAD_HOME = "${userHomes}/${name}"; HOME = "${userHomes}/${name}"; RUST_LOG = "info"; };
      path = [ pkgs.gitMinimal ];
      serviceConfig = {
        User = "radicle";
        Group = "radicle";
        ExecStartPre = "+${pkgs.writeShellScript "radicle-home-${name}" ''
          set -euo pipefail
          home=${userHomes}/${name}
          install -d -m 0700 -o radicle -g radicle "$home" "$home/keys"
          ${keyInstall} "$home/keys/radicle" "$home" ${lib.optionalString (u.identityFrom != null) (lib.escapeShellArg u.identityFrom)}
          chown -R radicle:radicle "$home/keys"
          ln -sfn ${userConfig name} "$home/config.json"
        ''}";
        ExecStart = "${package}/bin/radicle-node --force";
        Restart = "on-failure";
        RestartSec = "30";
        StateDirectory = "radicle-users/${name}";
        StateDirectoryMode = "0700";
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
        UMask = "0077";
      };
    }) cfg.users;
  }
  {
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
        HIDE_NODES = toString cfg.hideNodes;
        ORIGIN = "https://${config.bresilla.services.gitea.domain}";
        NODES = "${nodes}";
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
        ReadWritePaths = [ "/var/lib/radicle" "-${userHomes}" ];
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
          export PATH=${lib.makeBinPath [ pkgs.gnutar pkgs.zstd pkgs.age pkgs.age-plugin-yubikey pkgs.coreutils pkgs.findutils ]}
          out=/run/radicle-backup
          tar -C /var/lib --exclude='radicle-users/*/keys' -cf - radicle radicle-sync radicle-users \
            | zstd -q -T0 > "$out/radicle-state.tar.zst"
          ${lib.optionalString (cfg.backup.recipients != [ ]) ''
            cd /var/lib
            # shellcheck disable=SC2046
            tar -cf - radicle-identity $(find radicle-users -mindepth 2 -maxdepth 2 -name keys) | zstd -q \
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
  } ]);
}
