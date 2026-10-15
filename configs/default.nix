{ config, lib, ... }:

let
  configs = ./.;
  modules = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix")
    (builtins.readDir configs);
  # Folders link whole into the Nix store, read-only until the next rebuild.
  # Home Manager also writes inside fontconfig and systemd, so their entries link one by one.
  assetLinks = prefix: directory:
    lib.concatMapAttrs (name: type:
      let target = if prefix == "" then name else "${prefix}/${name}";
      in if type == "directory" && (lib.hasPrefix "fontconfig" target || lib.hasPrefix "systemd" target)
        then assetLinks target (directory + "/${name}")
        else { ${target}.source = directory + "/${name}"; }
    ) (builtins.readDir directory);
in
{
  # Each configs/<app>.nix takes over an app; delete its assets/<app> then.
  imports = map (name: configs + "/${name}") (builtins.attrNames modules);

  xdg.enable = true;
  xdg.configFile = assetLinks "" ./assets;
  home.file = lib.mapAttrs (name: _: { source = ./home + "/${name}"; }) (builtins.readDir ./home) // {
    ".zshenv".text = ''
      export ZDOTDIR="$HOME/.config/zsh"
      export NVIM_LOG_FILE=/dev/null
    '';
  };
  home.sessionPath = [ "${config.home.homeDirectory}/.local/bin" "${config.home.homeDirectory}/.local/sbin" ];

  # Morf saves the chosen look in state; the repository only seeds the first one.
  home.activation.seedMorfAppearance = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    state=${lib.escapeShellArg "${config.xdg.stateHome}/morf/appearance.json"}
    [[ -e "$state" ]] || run install -D -m 644 ${./assets/morf/caelestia/appearance.json} "$state"
  '';
}
