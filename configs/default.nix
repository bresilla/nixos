{ config, lib, ... }:

let
  configs = ./.;
  checkout = "${config.home.homeDirectory}/nixos/configs";
  link = config.lib.file.mkOutOfStoreSymlink;
  modules = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix")
    (builtins.readDir configs);
  # Folders link whole into the editable ~/nixos checkout. Home Manager also
  # writes inside fontconfig and systemd, so their entries link one by one.
  assetLinks = prefix: directory:
    lib.concatMapAttrs (name: type:
      let target = if prefix == "" then name else "${prefix}/${name}";
      in if type == "directory" && (lib.hasPrefix "fontconfig" target || lib.hasPrefix "systemd" target)
        then assetLinks target (directory + "/${name}")
        else { ${target}.source = link "${checkout}/assets/${target}"; }
    ) (builtins.readDir directory);
  copied = "${config.xdg.stateHome}/bresilla-configs/copied";
in
{
  # Each configs/<app>.nix takes over an app; delete its assets/<app> then.
  imports = map (name: configs + "/${name}") (builtins.attrNames modules);

  xdg.enable = true;
  xdg.configFile = assetLinks "" ./assets;
  home.file = lib.mapAttrs (name: _: { source = link "${checkout}/home/${name}"; }) (builtins.readDir ./home) // {
    ".zshenv".text = ''
      export ZDOTDIR="$HOME/.config/zsh"
      export NVIM_LOG_FILE=/dev/null
    '';
  };
  home.sessionPath = [ "${config.home.homeDirectory}/.local/bin" "${config.home.homeDirectory}/.local/sbin" ];

  # Copies from the earlier copy-based setup make way for the links once.
  home.activation.dropCopiedAssets = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    if [[ -f ${lib.escapeShellArg copied} ]]; then
      while IFS= read -r path; do run rm -f -- "$path"; done < ${lib.escapeShellArg copied}
      while IFS= read -r path; do
        run rmdir -p --ignore-fail-on-non-empty -- "$(dirname -- "$path")" 2>/dev/null || true
      done < ${lib.escapeShellArg copied}
      run rm -f -- ${lib.escapeShellArg copied}
    fi
  '';
}
