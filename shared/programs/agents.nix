{ config, lib, pkgs, llmAgents, aiNerv, termworks, ... }:

let
  agents = llmAgents.packages.${pkgs.stdenv.hostPlatform.system};
  nerv = aiNerv;
  wing = termworks.wing.packages.${pkgs.stdenv.hostPlatform.system}.wing or null;
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
    ];

    # Skills, agent profiles and rules come from the wing server (wing.bresilla.com), edited
    # there: `wing skill pull` links the skills into every coding tool, `wing agent pull` writes
    # each agent for every tool installed, `wing rules pull` the global rules and each project's
    # AGENTS.md. A machine not logged in (wing server login URL) waits.
    systemd.user.services.wing-sync = lib.mkIf (wing != null) {
      description = "Skills, agents and rules from the wing server";
      after = [ "network-online.target" ];
      path = [ wing pkgs.curl pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; TimeoutStartSec = "5min"; };
      script = ''
        if [ ! -s "''${XDG_DATA_HOME:-$HOME/.local/share}/wing/server.json" ]; then
          echo "not logged in to a wing server: wing server login https://wing.bresilla.com"
          exit 0
        fi
        wing skill pull --quiet
        # Agents need a wing that knows them (0.9 and later); --help is answered by any wing.
        if wing agent list > /dev/null 2>&1; then
          wing agent pull > /dev/null
        fi
        # Rules need 0.10 and later.
        if wing rules list > /dev/null 2>&1; then
          wing rules pull --quiet
        fi
      '';
    };
    systemd.user.timers.wing-sync = lib.mkIf (wing != null) {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnStartupSec = "1min"; OnUnitActiveSec = "30min"; RandomizedDelaySec = "2min"; };
    };

    # The shared Ollama server on lama, reachable over the VPN only; workstations run their own.
    environment.sessionVariables.OLLAMA_HOST = lib.mkDefault "lama.netbird:11434";
  };
}
