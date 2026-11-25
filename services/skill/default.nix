# skill.bresilla.com inside its container: a checkout of the skills repository, the
# index skillshare writes from it, the page over both, and Caddy on :8080 for the tunnel.
{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.skill;
  siteUi = import ../ui { inherit pkgs; };
  python = pkgs.python3.withPackages (p: [ p.markdown p.pyyaml ]);
  state = "/var/lib/skill";
  sandbox = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    CapabilityBoundingSet = [ "" ];
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    LockPersonality = true;
  };
in
{
  options.bresilla.services.skill = {
    domain = lib.mkOption { type = lib.types.str; };
    repo = lib.mkOption { type = lib.types.str; description = "The skills repository, cloned over HTTPS."; };
    skillshare = lib.mkOption { type = lib.types.package; };
  };

  config = {
    system.stateVersion = "26.05";
    users.users.skill = { isSystemUser = true; uid = 951; group = "skill"; home = state; };
    users.groups.skill.gid = 951;
    networking.firewall.allowedTCPPorts = [ 8080 ];
    networking.useHostResolvConf = false;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];

    # Clone or fast-forward the repository, then rebuild the index with its audit.
    systemd.services.skill-refresh = {
      description = "Pull ${cfg.repo} and index it for ${cfg.domain}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.git cfg.skillshare pkgs.coreutils ];
      environment.HOME = state;
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "skill";
        Group = "skill";
        StateDirectory = "skill";
        TimeoutStartSec = "5min";
      };
      script = ''
        if [ -d ${state}/repo/.git ]; then
          git -C ${state}/repo fetch --quiet --depth 1 origin
          git -C ${state}/repo reset --quiet --hard FETCH_HEAD
        else
          rm -rf ${state}/repo
          git clone --quiet --depth 1 ${cfg.repo} ${state}/repo
        fi
        skillshare hub index --source ${state}/repo --full --audit -o ${state}/skillshare-hub.json.new
        mv ${state}/skillshare-hub.json.new ${state}/skillshare-hub.json
      '';
    };
    systemd.timers.skill-refresh = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "5min"; };
    };

    systemd.services.skill-ui = {
      description = cfg.domain;
      wantedBy = [ "multi-user.target" ];
      environment = {
        PYTHONPATH = "${siteUi}";
        SKILL_REPO = "${state}/repo";
        SKILL_INDEX = "${state}/skillshare-hub.json";
        SKILL_LISTEN = "127.0.0.1:8094";
        SKILL_HOME = lib.removeSuffix ".git" (lib.removePrefix "https://" cfg.repo);
      };
      serviceConfig = sandbox // {
        ExecStart = "${python}/bin/python3 ${./skill.py}";
        Restart = "on-failure";
        User = "skill";
        Group = "skill";
        StateDirectory = "skill";
        RestrictAddressFamilies = [ "AF_INET" ];
      };
    };

    # Caddy on :8080, sandboxed like the page and without the packaged unit's capabilities.
    systemd.services.caddy.serviceConfig = sandbox // { ProtectSystem = lib.mkForce "strict"; };
    services.caddy = {
      enable = true;
      virtualHosts."http://:8080".extraConfig = ''
        ${import ../headers.nix}
        reverse_proxy 127.0.0.1:8094
      '';
    };
  };
}
