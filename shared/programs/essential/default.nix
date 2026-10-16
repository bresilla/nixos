{
  config,
  lib,
  pkgs,
  ...
}:
let
  essential = config.bresilla.programs.essential;
in
{
  options.bresilla.programs.essential = {
    enable = lib.mkEnableOption "essential command-line programs" // {
      default = true;
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        # Both provide cc and c++; Clang's win, GCC keeps gcc and g++.
        (lib.hiPrio clang)
        gcc
        curl
        fd
        fish
        fzf
        gitMinimal
        neovim
        rclone
        ripgrep
        rsync
        tmux
        unzip
        vim
        waypipe
        wget
        zip
        zsh
      ];
      description = "Essential packages installed on every host.";
    };
  };

  config = lib.mkIf essential.enable {
    environment.systemPackages = essential.packages;

    programs.nix-ld = {
      enable = true;
      libraries = with pkgs; [
        stdenv.cc.cc
        zlib
        zstd
        bzip2
        xz
        openssl
        curl
        libxml2
        sqlite
      ];
    };
  };
}
