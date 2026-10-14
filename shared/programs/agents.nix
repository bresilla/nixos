{ config, lib, pkgs, llmAgents, aiNerv, ... }:

let
  agents = llmAgents.packages.${pkgs.stdenv.hostPlatform.system};
  # ai-nerv's pinned static builds; absent until the updater has fetched them.
  nerv = name: lib.optional (aiNerv ? ${name}) aiNerv.${name};
in
{
  options.bresilla.programs.agents.enable = lib.mkEnableOption "coding agents" // {
    default = true;
  };

  # Packages come from llm-agents' own nixpkgs so they match cache.numtide.com.
  config = lib.mkIf config.bresilla.programs.agents.enable {
    environment.systemPackages = [
      agents.pi
      agents.maki
      agents.codex
      agents.muse-code
      agents.claude-code
      agents.antigravity-cli
    ]
    ++ nerv "magi"
    ++ nerv "casper"
    ++ nerv "melchior"
    ++ nerv "balthasar";
  };
}
