{ config, lib, pkgs, pkgsUnstable, ... }:

let
  desktop = config.bresilla.features.desktop;
in
{
  config = lib.mkIf config.bresilla.programs.essential.enable {
    environment.systemPackages = with pkgs; [
      # Shell and files
      argc
      asciinema
      atuin
      bat
      choose
      duf
      eva
      eza
      gomi
      jq
      pastel
      sd
      sl
      starship
      tab-rs
      tealdeer
      television
      yazi
      zoxide

      # Git and releases
      act
      cargo-release
      delta
      ec
      gh
      gh-dash
      git-cliff
      git-lfs
      git-town
      git-who
      gitmux
      hub
      jujutsu
      lazygit
      onefetch
      soft-serve
      tea

      # Development environments and editor tools
      bun
      deno
      devbox
      devenv
      direnv
      lua-language-server
      micromamba
      pixi
      uv
      gnumake

      # AI tools
      beads
      fabric-ai
      goose-cli
      opencode

      # Networking and transfer
      arp-scan
      bandwhich
      bore-cli
      boringtun
      cloudflared
      croc
      dufs
      ffsend
      innernet
      ipinfo
      mole
      netbird
      nmap
      portal
      qrcp
      rustscan
      socat
      sshfs
      termshark
      trippy
      warpgate
      websocat
      wireproxy

      # Credentials and encryption
      age
      gpg-tui
      horcrux
      proton-pass-cli
      step-cli

      # Documents, notes and media
      allmark
      anytype-cli
      bibiman
      dnote
      lockbook
      mdbook
      presenterm
      slides
      tectonic
      typst

      # System inspection
      cpufetch
      pik
      systemd-manager-tui

    ] ++ (with pkgsUnstable; [
      # These applications are currently absent from the stable package set.
      qrc
      unifly
    ]) ++ lib.optionals desktop.enable (with pkgs; [
      # Desktop applications and input utilities; services are configured separately.
      bluetuith
      mpd-mpris
      ncpamixer
      wdisplays
    ]) ++ lib.optionals (desktop.enable && desktop.environment == "hyprland") [
      pkgs.hyprdynamicmonitors
      pkgs.hyprsome
      pkgsUnstable.hyprscratch
    ];
  };
}
