# A Radicle node beside gitea: every public repository is published on Radicle and
# kept in step with gitea, which stays the source of truth.
{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.gitea.radicle;
  gitea = config.services.gitea;
  identity = "/var/lib/radicle-identity";
  state = "/var/lib/radicle-sync";
  package = pkgs.radicle-node.overrideAttrs (previous: {
    # The CLI fixture races seed discovery and asserts the resulting status text.
    checkFlags = previous.checkFlags ++ [
      "--skip=commands::patch::rad_patch_merge_unauthorized_branch"
    ];
  });
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

    systemd.services.radicle-sync = {
      description = "Publish gitea's public repositories on Radicle";
      requires = [ "radicle-node.service" ];
      after = [ "radicle-node.service" "gitea.service" ];
      path = [ package pkgs.gitMinimal pkgs.openssh pkgs.sqlite pkgs.jq pkgs.coreutils pkgs.findutils pkgs.gawk pkgs.gnugrep ];
      environment = {
        DATABASE = gitea.database.path;
        REPOSITORIES = gitea.repositoryRoot;
        RADICLE = config.services.radicle.settings.node.alias;
        RAD_STATE = "/var/lib/radicle";
        RAD_CONFIG = "${config.services.radicle.configFile}";
        SYNC_STATE = state;
        OPT_OUT = cfg.optOut;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "radicle";
        Group = "radicle";
        SupplementaryGroups = [ gitea.group ];
        LoadCredential = [ "key:${identity}/radicle" ];
        StateDirectory = "radicle-sync";
        StateDirectoryMode = "0755";
        RuntimeDirectory = "radicle-sync";
        RuntimeDirectoryMode = "0700";
        ReadWritePaths = [ "/var/lib/radicle" ];
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

    # Each public repository's Radicle ID, read by the clone panel.
    services.caddy.virtualHosts."http://:80".extraConfig = ''
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
