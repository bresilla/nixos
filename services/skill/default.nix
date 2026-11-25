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

    # Clone or fast-forward the repository, then write the index, the audit and the history.
    systemd.services.skill-refresh = {
      description = "Pull ${cfg.repo} and index it for ${cfg.domain}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.git cfg.skillshare pkgs.coreutils pkgs.jq ];
      environment = {
        HOME = state;
        SKILLSHARE_CONFIG = "${state}/config.yaml";
      };
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "skill";
        Group = "skill";
        StateDirectory = "skill";
        TimeoutStartSec = "5min";
      };
      script = ''
        if [ -d ${state}/repo/.git ] && [ ! -f ${state}/repo/.git/shallow ]; then
          git -C ${state}/repo fetch --quiet origin
          git -C ${state}/repo reset --quiet --hard FETCH_HEAD
        else
          rm -rf ${state}/repo
          git clone --quiet ${cfg.repo} ${state}/repo
        fi
        printf 'sources:\n  skills: %s\ntargets: {}\n' ${state}/repo > ${state}/config.yaml

        skillshare hub index --source ${state}/repo --full --audit -o ${state}/skillshare-hub.json.new
        mv ${state}/skillshare-hub.json.new ${state}/skillshare-hub.json

        skillshare audit --format json --yes > ${state}/audit.json.new || true
        if jq -e .results ${state}/audit.json.new > /dev/null; then
          mv ${state}/audit.json.new ${state}/audit.json
        else
          rm -f ${state}/audit.json.new
        fi

        git -C ${state}/repo log -n 500 --name-only --format=$'\x1e%H\x1f%an\x1f%aI\x1f%s' > ${state}/history.txt.new
        mv ${state}/history.txt.new ${state}/history.txt
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
        SKILL_STATE = state;
        SKILL_DOMAIN = cfg.domain;
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
