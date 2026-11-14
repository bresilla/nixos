# RustFS, an S3 server, for a NixOS container: buckets on /srv/s3, the S3 API and
# its console on one port behind Caddy. Caddy serves the console from our own
# build in the look of the other sites; the copy built into RustFS stays off.
{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.services.s3;
  console = import ./console.nix { inherit pkgs; console = cfg.console; };
  # The root key, made once in the container and never in git.
  rootEnv = "/var/lib/s3/root.env";
in {
  options.bresilla.services.s3 = {
    domain = lib.mkOption { type = lib.types.str; description = "The public name of the API and console."; };
    proxy = lib.mkOption { type = lib.types.str; description = "Address of the proxy in front of it."; };
    uid = lib.mkOption { type = lib.types.int; description = "Fixed rustfs user, so files on shared storage keep their owner."; };
    package = lib.mkOption { type = lib.types.package; description = "RustFS itself; nixpkgs-unstable's, until the stable channel has it."; };
    console = lib.mkOption { type = lib.types.package; description = "RustFS's console build, which gets the shared look."; };
    login = lib.mkOption {
      default = null;
      description = "Sign-in to the console through an OpenID Connect provider such as id.bresilla.com.";
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          name = lib.mkOption { type = lib.types.str; description = "Shown on the sign-in button."; };
          discovery = lib.mkOption { type = lib.types.str; };
          client = lib.mkOption { type = lib.types.str; };
          envFile = lib.mkOption { type = lib.types.str; description = "Holds RUSTFS_IDENTITY_OPENID_CLIENT_SECRET."; };
          policyClaim = lib.mkOption { type = lib.types.str; description = "Claim whose values name the RustFS policies a person gets."; };
        };
      });
    };
  };

  config = {
    users.users.rustfs = { isSystemUser = true; uid = cfg.uid; group = "rustfs"; };
    users.groups.rustfs.gid = cfg.uid;

    systemd.services.s3-root = {
      description = "RustFS's root key";
      before = [ "rustfs.service" ];
      requiredBy = [ "rustfs.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      path = [ pkgs.openssl pkgs.coreutils ];
      script = ''
        install -d -m 0700 /var/lib/s3
        [ -s ${rootEnv} ] && exit 0
        (umask 077; printf 'RUSTFS_ACCESS_KEY=root\nRUSTFS_SECRET_KEY=%s\n' "$(openssl rand -hex 24)" > ${rootEnv})
      '';
    };

    systemd.services.rustfs = {
      description = "RustFS object storage";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ "/srv/s3" ];
      environment = {
        RUSTFS_VOLUMES = "/srv/s3/data";
        RUSTFS_ADDRESS = "127.0.0.1:9000";
        RUSTFS_CONSOLE_ENABLE = "false";
        # Where sign-in sends the browser back to; RustFS adds the console's path.
        RUSTFS_BROWSER_REDIRECT_URL = "https://${cfg.domain}";
        RUSTFS_OBS_LOG_DIRECTORY = "/var/lib/rustfs/logs";
      } // lib.optionalAttrs (cfg.login != null) {
        RUSTFS_IDENTITY_OPENID_ENABLE = "on";
        RUSTFS_IDENTITY_OPENID_CONFIG_URL = cfg.login.discovery;
        RUSTFS_IDENTITY_OPENID_CLIENT_ID = cfg.login.client;
        RUSTFS_IDENTITY_OPENID_SCOPES = "openid,profile,email";
        RUSTFS_IDENTITY_OPENID_CLAIM_NAME = cfg.login.policyClaim;
        RUSTFS_IDENTITY_OPENID_DISPLAY_NAME = cfg.login.name;
        RUSTFS_IDENTITY_OPENID_REDIRECT_URI = "https://${cfg.domain}/rustfs/admin/v3/oidc/callback/default";
        RUSTFS_IDENTITY_OPENID_REDIRECT_URI_DYNAMIC = "off";
      };
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "main";
        User = "rustfs";
        Group = "rustfs";
        StateDirectory = "rustfs";
        EnvironmentFile = [ rootEnv ] ++ lib.optional (cfg.login != null) cfg.login.envFile;
        # As rustfs: the container's root cannot write nest's share.
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /srv/s3/data";
        ExecStart = lib.getExe cfg.package;
        LimitNOFILE = 1048576;
        Restart = "always";
        RestartSec = "10s";
        TimeoutStartSec = "60s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/srv/s3" ];
        ProtectHome = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        UMask = "0077";
      };
    };

    # One port: the console from its themed build, everything else to RustFS.
    services.caddy = {
      enable = true;
      globalConfig = ''
        servers {
          trusted_proxies static ${cfg.proxy}/32
        }
      '';
      virtualHosts."http://:80".extraConfig = ''
        ${import ../headers.nix}
        handle /rustfs/console* {
          root * ${console}
          try_files {path} {path}index.html {path}/index.html /rustfs/console/index.html
          file_server
        }
        # A browser at the bare name goes to the console; S3 clients sign their requests.
        @browser {
          method GET
          path /
          not header Authorization *
          not query X-Amz-Signature=*
        }
        redir @browser /rustfs/console/ 302
        handle {
          reverse_proxy 127.0.0.1:9000
        }
      '';
    };

    system.stateVersion = "26.05";
    # Only the host reaches this network.
    networking.firewall.enable = false;
    # The host's resolver listens on its own loopback, which this network can't reach.
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
  };
}
