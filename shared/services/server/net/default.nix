# innernet's coordinating servers and net.bresilla.com, their page. Every network
# is skynet<n>, its interface named the same, on a port of its own. The page
# listens only inside the networks (and, for the CA's check, on the link to hive);
# signing in goes through id.bresilla.com.
# Each database is innernet's own; after every change it is encrypted to the backup
# recipients, which hive copies to nest and out for gopass (README.md).
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.net;
  siteUi = import ../ui { inherit pkgs; };
  server = "${pkgs.innernet}/bin/innernet-server";
  sqlite = "${pkgs.sqlite}/bin/sqlite3";
  encrypt = lib.concatMapStringsSep " " (r: "-r ${lib.escapeShellArg r}") cfg.backup.recipients;
  names = lib.attrNames cfg.networks;
  perNetwork = f: lib.mkMerge (lib.mapAttrsToList f cfg.networks);
  network = lib.types.submodule {
    options = {
      cidr = lib.mkOption { type = lib.types.str; description = "The whole network's range; the server takes its first address."; };
      endpoint = lib.mkOption { type = lib.types.str; description = "host:port every peer reaches this network's server at."; };
      port = lib.mkOption { type = lib.types.port; description = "Its WireGuard port, and its API's inside."; };
      groups = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Groups made with the network, name to range; the page changes them afterwards.";
      };
      access = lib.mkOption {
        type = lib.types.listOf (lib.types.listOf lib.types.str);
        default = [ ];
        description = "Pairs of groups that reach each other, set with the network; the page changes them afterwards.";
      };
    };
  };
in
{
  options.bresilla.services.net = {
    networks = lib.mkOption {
      type = lib.types.attrsOf network;
      description = "The networks, named skynet0, skynet1, …; each is also its interface's name.";
    };
    domain = lib.mkOption { type = lib.types.str; description = "The page's name, resolved only inside."; };
    login = {
      issuer = lib.mkOption { type = lib.types.str; };
      client = lib.mkOption { type = lib.types.str; };
      envFile = lib.mkOption { type = lib.types.str; description = "Holds the login proxy's client and cookie secrets."; };
      adminClaim = lib.mkOption { type = lib.types.str; description = "Claim whose value \"admin\" lets a user in."; };
    };
    ca = lib.mkOption {
      default = null;
      description = "The CA Caddy gets the certificate from over ACME; without it, Caddy's own internal one.";
      type = lib.types.nullOr (lib.types.submodule {
        options.directory = lib.mkOption { type = lib.types.str; };
        options.root = lib.mkOption { type = lib.types.path; };
        options.name = lib.mkOption { type = lib.types.str; };
        options.address = lib.mkOption { type = lib.types.str; };
      });
    };
    caChecker = lib.mkOption { type = lib.types.str; description = "The CA's own address, the only one let in on the link."; };
    backup.recipients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "age recipients the servers' keys and databases are encrypted to, as gopass's.";
    };
  };

  config = lib.mkMerge [ {
    assertions = [ {
      assertion = lib.all (n: builtins.match "skynet[0-9]+" n != null) names;
      message = "innernet networks are named skynet0, skynet1, …; got ${toString names}";
    } ];
    system.stateVersion = "26.05";
    environment.systemPackages = [ pkgs.innernet pkgs.wireguard-tools pkgs.sqlite ];
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
    networking.hosts = lib.mkIf (cfg.ca != null) { ${cfg.ca.address} = [ cfg.ca.name ]; };

    # WireGuard from anywhere; the page and each network's API only from inside it,
    # the page also for the CA's check.
    networking.nftables.enable = true;
    networking.firewall = {
      allowedUDPPorts = lib.mapAttrsToList (_: n: n.port) cfg.networks;
      interfaces = lib.mapAttrs (_: n: { allowedTCPPorts = [ 443 n.port ]; }) cfg.networks;
      extraInputRules = "iifname \"eth0\" ip saddr ${cfg.caChecker} tcp dport 443 accept";
    };
  }

  { systemd = perNetwork (net: n: let
    db = "/var/lib/innernet-server/${net}.db";
    conf = "/etc/innernet-server/${net}.conf";
    backup = "/var/lib/net-backup/${net}";
  in {
    # Made once: the network, its first groups and their access. Never again, so a
    # restored database is kept as it is.
    services."innernet-${net}-init" = {
      description = "Create innernet network ${net}";
      before = [ "innernet-server-${net}.service" ];
      requiredBy = [ "innernet-server-${net}.service" ];
      unitConfig.ConditionPathExists = "!${conf}";
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${server} new --network-name ${net} --network-cidr ${n.cidr} \
          --external-endpoint ${n.endpoint} --listen-port ${toString n.port}
        ${lib.concatStrings (lib.mapAttrsToList (name: range: ''
          ${server} add-cidr ${net} --name ${name} --cidr ${range} --parent ${net} --yes
        '') n.groups)}
        ${lib.concatMapStrings (pair: ''
          ${sqlite} ${db} "INSERT INTO associations (cidr_id_1, cidr_id_2)
            SELECT a.id, b.id FROM cidrs a, cidrs b WHERE a.name = '${lib.elemAt pair 0}' AND b.name = '${lib.elemAt pair 1}'"
        '') n.access}
      '';
    };

    services."innernet-server-${net}" = {
      description = "innernet server for ${net}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment.RUST_LOG = "info";
      serviceConfig = {
        # /etc/hosts belongs to NixOS.
        ExecStart = "${server} serve ${net} --no-write-hosts";
        Restart = "always";
        RestartSec = 1;
      };
    };

    # After every change worth keeping: the database without the peers' ever-changing
    # endpoints, and the server's config, each encrypted only when it differs.
    services."net-backup-${net}" = {
      description = "Encrypted copy of ${net}'s key and database";
      after = [ "innernet-${net}-init.service" ];
      path = [ pkgs.age pkgs.age-plugin-yubikey pkgs.sqlite pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; UMask = "0077"; };
      script = ''
        [ -s ${db} ] && [ -s ${conf} ] || exit 0
        install -d -m 0700 ${backup}
        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT
        sqlite3 ${db} ".backup $work/db"
        sqlite3 "$work/db" "UPDATE peers SET endpoint = NULL, candidates = '[]' WHERE name <> 'innernet-server'"
        sqlite3 "$work/db" .dump > "$work/dump"
        cp ${conf} "$work/server"
        for f in db:dump server:server; do
          name=''${f%%:*} src=$work/''${f#*:}
          sum=$(sha256sum < "$src" | cut -d' ' -f1)
          [ "$(cat ${backup}/$name.sum 2>/dev/null)" = "$sum" ] && continue
          age ${encrypt} -o ${backup}/$name.age.new "$src"
          mv ${backup}/$name.age.new ${backup}/$name.age
          echo "$sum" > ${backup}/$name.sum
          echo "$name changed: new encrypted copy"
        done
      '';
    };
    paths."net-backup-${net}" = {
      wantedBy = [ "paths.target" ];
      pathConfig = { PathChanged = db; TriggerLimitIntervalSec = "10s"; TriggerLimitBurst = 1; };
    };
    timers."net-backup-${net}" = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "hourly"; Persistent = true; };
    };
  }); }

  {
    systemd.services.net-ui = {
      description = "net.bresilla.com";
      after = map (net: "innernet-server-${net}.service") names;
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.innernet pkgs.wireguard-tools ];
      environment = {
        PYTHONPATH = "${siteUi}";
        NET_NAMES = toString names;
        NET_SERVER = server;
        NET_WG = "${pkgs.wireguard-tools}/bin/wg";
        NET_LISTEN = "127.0.0.1:8092";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./net.py}";
        Restart = "on-failure";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/innernet-server" "/etc/innernet-server" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" "AF_INET" "AF_INET6" ];
        LockPersonality = true;
      };
    };

    services.caddy = {
      enable = true;
      globalConfig = "auto_https disable_redirects";
      virtualHosts."${cfg.domain}:443".extraConfig = ''
        ${if cfg.ca == null then "tls internal" else ''
        # A one-day certificate from bresilla's CA; it checks this very port (TLS-ALPN).
        tls {
          issuer acme {
            dir ${cfg.ca.directory}
            trusted_roots ${cfg.ca.root}
            disable_http_challenge
          }
        }''}
        ${import ../headers.nix}
        handle /oauth2/* {
          reverse_proxy 127.0.0.1:4180
        }
        # Signed in or off to id.bresilla.com; the name and role come only from the proxy.
        # route keeps this order: stripping after forward_auth would drop its headers.
        handle {
          route {
            request_header -X-Forwarded-User
            request_header -X-Forwarded-Preferred-Username
            request_header -X-Forwarded-Groups
            request_header -X-Forwarded-Email
            forward_auth 127.0.0.1:4180 {
              uri /oauth2/auth
              copy_headers X-Auth-Request-Preferred-Username>X-Forwarded-Preferred-Username X-Auth-Request-Groups>X-Forwarded-Groups
              @out status 401
              handle_response @out {
                redir * /oauth2/start?rd={uri}
              }
            }
            reverse_proxy 127.0.0.1:8092
          }
        }
      '';
    };

    systemd.services.oauth2-proxy = {
      after = [ "network-online.target" "resolvconf.service" ];
      wants = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      serviceConfig.RestartSec = 10;
    };
    services.oauth2-proxy = {
      enable = true;
      provider = "oidc";
      clientID = cfg.login.client;
      keyFile = cfg.login.envFile;
      oidcIssuerUrl = cfg.login.issuer;
      redirectURL = "https://${cfg.domain}/oauth2/callback";
      httpAddress = "http://127.0.0.1:4180";
      upstream = [ "http://127.0.0.1:8092" ];
      email.domains = [ "*" ];
      reverseProxy = true;
      trustedProxyIP = [ "127.0.0.1" ];
      scope = "openid email profile";
      cookie = { name = "_net_login"; secure = true; expire = "24h0m0s"; };
      approvalPrompt = "auto";
      passBasicAuth = false;
      extraConfig = {
        skip-provider-button = true;
        whitelist-domain = builtins.elemAt (lib.splitString "/" cfg.login.issuer) 2;
        code-challenge-method = "S256";
        oidc-groups-claim = cfg.login.adminClaim;
        set-xauthrequest = true;
        insecure-oidc-allow-unverified-email = true;
      };
    };
  } ];
}
