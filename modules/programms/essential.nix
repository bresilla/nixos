{ config, lib, pkgs, ... }:

let
  cfg = config.bresilla.programs.essential;
in
{
  options.bresilla.programs.essential = {
    enable = lib.mkEnableOption "essential command-line programs" // {
      default = true;
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        curl
        alacritty
        fish
        gitMinimal
        kitty
        neovim
        tmux
        vim
        waypipe
        wget
        zsh
      ];
      description = "Essential packages installed on every host.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = cfg.packages;
  };
}
