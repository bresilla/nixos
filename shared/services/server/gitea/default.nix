# Gitea with a branded theme and a nightly backup, for a NixOS container. The host adds
# the container and its storage at /srv/gitea.
{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.gitea;
  gitea = config.services.gitea;
  siteUi = import ../ui { inherit pkgs; };
  # Overrides of gitea's own templates and assets, plus PNG icons from the SVG logo.
  custom = pkgs.runCommand "gitea-custom" { nativeBuildInputs = [ pkgs.librsvg ]; } ''
    cp -r ${./templates} templates
    mkdir -p public/assets/img
    chmod -R u+w templates public
    img=public/assets/img
    cp ${siteUi}/logo-black.svg $img/logo.svg
    substituteInPlace templates/custom/header.tmpl \
      --replace-fail @SITE_SCRIPT@ "$(cat ${siteUi}/theme.js)" \
      --replace-fail @SITE_STYLE@ "$(cat ${siteUi}/tokens.css)" \
      --replace-fail @GITEA_STYLE@ "$(cat ${./theme.css})"
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
    proxy = lib.mkOption {
      type = lib.types.str;
      description = "Address of the proxy in front of it, trusted for the client's address.";
    };
    login = lib.mkOption {
      default = null;
      description = "Sign-in through an OpenID Connect provider such as id.bresilla.com.";
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          name = lib.mkOption { type = lib.types.str; description = "Login source name; part of the callback URL."; };
          discovery = lib.mkOption { type = lib.types.str; description = "The provider's openid-configuration URL."; };
          client = lib.mkOption { type = lib.types.str; };
          secretFile = lib.mkOption { type = lib.types.str; };
          adminClaim = lib.mkOption { type = lib.types.str; description = "Claim whose value \"admin\" makes a gitea admin."; };
        };
      });
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
          # Only Caddy reaches it; the tunnel comes in there.
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = 3000;
          START_SSH_SERVER = true;
          # Clone URLs use port 22; the host forwards it to 2222.
          SSH_DOMAIN = cfg.domain;
          SSH_PORT = 22;
          SSH_LISTEN_PORT = 2222;
        };
        # Accounts come only from the login provider (who may sign in is decided
        # there), and link to an existing one by username. As on cache and build,
        # anyone may look and clone what is public; signing in goes straight to the
        # provider, no other way in is offered. The local admin stays, for when the
        # provider is down.
        service = if cfg.login == null then { DISABLE_REGISTRATION = true; } else {
          DISABLE_REGISTRATION = false;
          ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
          ENABLE_PASSWORD_SIGNIN_FORM = false;
          ENABLE_PASSKEY_AUTHENTICATION = false;
        };
        openid = lib.mkIf (cfg.login != null) { ENABLE_OPENID_SIGNIN = false; ENABLE_OPENID_SIGNUP = false; };
        oauth2_client = lib.mkIf (cfg.login != null) {
          ENABLE_AUTO_REGISTRATION = true;
          USERNAME = "preferred_username";
          ACCOUNT_LINKING = "auto";
          UPDATE_AVATAR = false;
        };
        # Follows the OS light/dark setting, which the logo and accent also follow.
        ui = { DEFAULT_THEME = "gitea-auto"; THEMES = "gitea-auto"; };
        # Repositories are what is public: no list of accounts, no API browser.
        "service.explore".DISABLE_USERS_PAGE = true;
        api.ENABLE_SWAGGER = false;
        attachment.PATH = "/srv/gitea/attachments";
      };
    };

    # In front for the headers gitea cannot send itself; it passes the visitor's
    # address on, which gitea trusts from loopback.
    services.caddy = {
      enable = true;
      globalConfig = ''
        servers {
          trusted_proxies static ${cfg.proxy}/32
        }
      '';
      virtualHosts."http://:80".extraConfig = ''
        ${import ../headers.nix}
        reverse_proxy 127.0.0.1:3000
      '';
    };

    # Nightly database and secrets copy next to the repos; 14 days kept.
    # The login source in gitea's database, kept as declared here on every start.
    systemd.services.gitea-login = lib.mkIf (cfg.login != null) {
      description = "Sign-in through ${cfg.login.name}";
      # It fetches the provider's configuration, so it needs names resolving first.
      after = [ "gitea.service" "network-online.target" "resolvconf.service" ];
      wants = [ "network-online.target" ];
      requires = [ "gitea.service" ];
      wantedBy = [ "multi-user.target" ];
      environment.GITEA_WORK_DIR = gitea.stateDir;
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = 15;
        User = "gitea";
        LoadCredential = [ "secret:${cfg.login.secretFile}" ];
      };
      script = let
        cli = "${gitea.package}/bin/gitea admin auth --config ${gitea.customDir}/conf/app.ini";
      in ''
        args=(--name ${cfg.login.name} --provider openidConnect --key ${cfg.login.client}
          --secret "$(< "$CREDENTIALS_DIRECTORY/secret")" --auto-discover-url ${cfg.login.discovery}
          --scopes openid --scopes email --scopes profile
          --group-claim-name ${cfg.login.adminClaim} --admin-group admin --skip-local-2fa)
        id=$(${cli} list | ${pkgs.gawk}/bin/awk -v n=${cfg.login.name} '$2 == n { print $1 }')
        if [ -n "$id" ]; then ${cli} update-oauth --id "$id" "''${args[@]}"
        else ${cli} add-oauth "''${args[@]}"; fi
      '';
    };

    systemd.services.gitea-backup = {
      # Confined like gitea itself: it only reads the database and writes the backup.
      serviceConfig = {
        Type = "oneshot";
        User = gitea.user;
        Group = gitea.group;
        ReadWritePaths = [ "/srv/gitea/backups" (dirOf gitea.database.path) ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectProc = "invisible";
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
        UMask = "0027";
      };
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
