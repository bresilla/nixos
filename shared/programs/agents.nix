{ config, lib, pkgs, llmAgents, aiNerv, ... }:

let
  agents = llmAgents.packages.${pkgs.stdenv.hostPlatform.system};
  nerv = aiNerv;
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

    # The shared Ollama server on lama, reachable over the VPN only; workstations run their own.
    environment.sessionVariables.OLLAMA_HOST = lib.mkDefault "lama.netbird:11434";
  };
}
