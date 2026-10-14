{ config, lib, pkgs, llmAgents, aiNerv, ... }:

let
  agents = llmAgents.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  options.bresilla.programs.agents.enable = lib.mkEnableOption "coding agents" // {
    default = true;
  };

  # Packages come from llm-agents' own nixpkgs so they match cache.numtide.com.
  # ai-nerv's magi, casper, melchior and balthasar are its pinned static builds.
  config = lib.mkIf config.bresilla.programs.agents.enable {
    environment.systemPackages = [
      agents.pi
      agents.maki
      agents.codex
      agents.muse-code
      agents.claude-code
      agents.antigravity-cli
    ] ++ builtins.attrValues aiNerv;
  };
}
