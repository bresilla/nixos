{ config, lib, pkgs, llmAgents, aiNerv, bresilla, ... }:

let
  agents = llmAgents.packages.${pkgs.stdenv.hostPlatform.system};
  nerv = aiNerv;
  skillshare = bresilla.skillshare or null;
  skills = {
    fetch = "https://git.bresilla.com/bresilla/skills.git";
    push = "gitea@git.bresilla.com:bresilla/skills.git";
  };
in
{
  options.bresilla.programs.agents.enable = lib.mkEnableOption "coding agents" // {
    default = true;
  };

  # llm-agents come from its own nixpkgs so they match cache.numtide.com;
  # nerv tools are ai-nerv's pinned static builds fetched by the updater.
  config = lib.mkIf config.bresilla.programs.agents.enable {
    # nerv tools are null until the updater has fetched their pins.
    environment.systemPackages = builtins.filter (p: p != null) [
      agents.pi
      agents.maki
      agents.prime-agent
      agents.opencode2
      agents.codex
      agents.grok
      agents.muse-code
      agents.claude-code
      agents.antigravity-cli

      agents.tokscale
      agents.beads
      agents.voxtype
      pkgs.ollama

      nerv.magi
      nerv.casper
      nerv.melchior
      nerv.balthasar

      # One set of skills, agents and MCP servers for every tool (configs/assets/skillshare).
      skillshare
    ];

    # The skills repository in ~/.local/share/skillshare/skills: cloned once, then pulled
    # and linked into every agent; local changes stay until `skillshare push`.
    systemd.user.services.skillshare-pull = lib.mkIf (skillshare != null) {
      description = "Pull the skills from ${skills.fetch} and link them into every agent";
      after = [ "network-online.target" ];
      path = [ skillshare pkgs.git pkgs.openssh pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; TimeoutStartSec = "5min"; };
      script = ''
        dir="$HOME/.local/share/skillshare/skills"
        if [ ! -d "$dir/.git" ]; then
          mkdir -p "$(dirname "$dir")"
          if [ -e "$dir" ]; then mv "$dir" "$dir.old-$(date +%Y%m%d%H%M%S)"; fi
          git clone --quiet ${skills.fetch} "$dir"
          git -C "$dir" remote set-url --push origin ${skills.push}
          skillshare sync
        else
          skillshare pull || skillshare sync
        fi
      '';
    };
    systemd.user.timers.skillshare-pull = lib.mkIf (skillshare != null) {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnStartupSec = "1min"; OnUnitActiveSec = "30min"; RandomizedDelaySec = "2min"; };
    };

    # The shared Ollama server on lama, reachable over the VPN only; workstations run their own.
    environment.sessionVariables.OLLAMA_HOST = lib.mkDefault "lama.netbird:11434";
  };
}
