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

    # The same clone at boot whenever ~/.dot is missing, so a machine installed any other
    # way (nixos-anywhere, an image) still gets the files ~/.config links to.
    systemd.services.dotfiles-checkout = lib.mkIf cfg.enable {
      description = "Clone the dotfiles into ~/.dot";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      before = [ "display-manager.service" ];
      unitConfig.ConditionPathExists = "!${home}/.dot";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = config.system.build.prepareDotfiles;
        # No network yet on the first boot: try again until GitHub answers.
        Restart = "on-failure";
        RestartSec = "30s";
      };
    };
  };
}
