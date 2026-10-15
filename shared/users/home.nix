{
  config,
  lib,
  pkgs,
  ...
}:

let
  user = config.bresilla.user.name;
  home = config.users.users.${user}.home;
  cfg = config.bresilla.configs;
in
{
  options.bresilla.configs.enable =
    lib.mkEnableOption "dotfiles from configs/, linked through the ~/.dot checkout" // {
      default = true;
    };

  config = {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "before-home-manager";
      users.${user} = {
        imports = lib.optional cfg.enable ../../configs;
        home.username = user;
        home.homeDirectory = home;
        home.stateVersion = "26.05";
      };
    };

    # The installer always runs this; it keeps this repository cloned in ~/.dot.
    system.build.prepareDotfiles = if cfg.enable then pkgs.writeShellScript "prepare-configs" ''
      export PATH=${lib.makeBinPath [ pkgs.gitMinimal pkgs.coreutils ]}:"$PATH"
      exec ${pkgs.bash}/bin/bash ${../installer/prepare-configs.sh} "''${1:-}"${lib.escapeShellArg home} ${../installer/update-dotfiles.sh}
    '' else pkgs.writeShellScript "prepare-configs" "exit 0";
  };
}
