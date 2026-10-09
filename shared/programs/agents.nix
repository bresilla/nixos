{ pkgs, llmAgents, ... }:

let
  agents = llmAgents.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  # Packages come from llm-agents' own nixpkgs so they match cache.numtide.com.
  environment.systemPackages = [
    agents.pi
    agents.opencode
    agents.codex
    agents.claude-code
  ];
}
