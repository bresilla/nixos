{ config, lib, pkgs, ... }:

let
  configs = ./.;
  modules = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix")
    (builtins.readDir configs);
in
{
  # Each configs/<app>.nix takes over an app; delete its assets/<app> then.
  imports = map (name: configs + "/${name}") (builtins.attrNames modules);

  xdg.enable = true;
  home.file.".zshenv".text = ''
    export ZDOTDIR="$HOME/.config/zsh"
    export NVIM_LOG_FILE=/dev/null
  '';
  home.sessionPath = [ "${config.home.homeDirectory}/.local/bin" "${config.home.homeDirectory}/.local/sbin" ];

  # Assets are copied, not linked: editable, but reset on every rebuild and boot.
  home.activation.copyAssets = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${pkgs.bash}/bin/bash ${./copy-assets.sh} \
      ${lib.escapeShellArg "${config.xdg.stateHome}/bresilla-configs/copied"} \
      ${./assets} "$HOME/.config" \
      ${./home} "$HOME"
  '';
}
