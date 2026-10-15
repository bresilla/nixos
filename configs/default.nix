{ config, lib, ... }:

let
  configs = ./.;
  # The updater keeps this repository cloned here; edits apply without a rebuild.
  checkout = "${config.home.homeDirectory}/.dot/configs";
  link = config.lib.file.mkOutOfStoreSymlink;
  modules = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix")
    (builtins.readDir configs);
  # Folders link whole into ~/.dot. Home Manager also writes inside
  # fontconfig and systemd, so their entries link one by one.
  assetLinks = prefix: directory:
    lib.concatMapAttrs (name: type:
      let target = if prefix == "" then name else "${prefix}/${name}";
      in if type == "directory" && (lib.hasPrefix "fontconfig" target || lib.hasPrefix "systemd" target)
        then assetLinks target (directory + "/${name}")
        else { ${target}.source = link "${checkout}/assets/${target}"; }
    ) (builtins.readDir directory);
in
{
  # Each configs/<app>.nix takes over an app; delete its assets/<app> then.
  imports = map (name: configs + "/${name}") (builtins.attrNames modules);

  xdg.enable = true;
  xdg.configFile = assetLinks "" ./assets;
  home.file = lib.mapAttrs (name: _: { source = link "${checkout}/home/${name}"; }) (builtins.readDir ./home);
  home.sessionPath = [ "${config.home.homeDirectory}/.local/bin" "${config.home.homeDirectory}/.local/sbin" ];
}
