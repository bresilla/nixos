{ pkgs, llmAgents, ... }:

let
  agents = llmAgents.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  # Packages come from llm-agents' own nixpkgs so they match cache.numtide.com.
  environment.systemPackages = [
    agents.pi
    agents.codex
    agents.copilot-cli
    agents.goose-cli
    agents.maki
    agents.muse-code
    agents.claude-code
  ];
}
