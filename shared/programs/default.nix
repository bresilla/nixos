{
  config,
  lib,
  pkgs,
  ...
}:
let
  essential = config.bresilla.programs.essential;
  system = config.bresilla.programs.system;
in
{
  imports = [
    ./terminal.nix
    ./termworks.nix
    ./agents.nix
    ./paneworks.nix
    ./desktop.nix
    ./flatpak.nix
    ./appimage.nix
  ];

  options.bresilla.programs.essential = {
    enable = lib.mkEnableOption "essential command-line programs" // {
      default = true;
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
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

  options.bresilla.programs.system = {
    enable = lib.mkEnableOption "system inspection and maintenance programs" // {
      default = true;
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        btop
        ethtool
        evtest
        lsb-release
        lm_sensors
        ncdu
        nvme-cli
        pciutils
        usbutils
        v4l-utils
      ];
      description = "System-level tools installed on every host.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf essential.enable {
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
    })
    (lib.mkIf system.enable { environment.systemPackages = system.packages; })
  ];
}
