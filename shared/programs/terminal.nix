{ config, lib, pkgs, pkgsUnstable, ... }:

let
  desktop = config.bresilla.features.desktop;
in
{
  config = lib.mkIf config.bresilla.programs.essential.enable {
    nixpkgs.config.allowUnfreePredicate = package:
      builtins.elem (lib.getName package) [ "crush" "duplicacy" "ookla-speedtest" ];

    environment.systemPackages = with pkgs; [
      # Shell and files
      aliae
      argc
      artem
      asciinema
      atuin
      bat
      choose
      cod
      dua
      duf
      duplicacy
      dutree
      entr
      erdtree
      eva
      eza
      f2
      fcp
      fx
      genact
      gomi
      grex
      gum
      has
      hck
      httm
      jq
      nnn
      oh-my-posh
      pastel
      peep
      pet
      rare-regex
      sd
      serpl
      sig
      sl
      starship
      tab-rs
      tailspin
      tealdeer
      television
      trashy
      tuc
      viu
      yazi
      zellij
      zoxide

      # Git and releases
      act
      cargo-release
      delta
      ec
      fac
      gh
      gh-dash
      git-cliff
      git-lfs
      git-town
      git-who
      gitmux
      gitstatus
      hub
      jujutsu
      lazygit
      onefetch
      soft-serve
      tea

      # Development environments and editor tools
      bun
      cobra-cli
      deno
      devbox
      devenv
      direnv
      dtool
      go-outline
      gocode-gomod
      godef
      golint
      gopkgs
      lazydocker
      leetcode-cli
      lua-language-server
      micromamba
      pixi
      pprof
      uv
      zls
      # Make is global; compilers and other build tools stay in project shells.
      gnumake

      # AI tools
      aichat
      beads
      codegrab
      codex
      crush
      fabric-ai
      goose-cli
      kardolus-chatgpt-cli
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
      fosrl-newt
      fosrl-olm
      gotify-cli
      gotty
      gping
      grepcidr
      innernet
      intermodal
      ipinfo
      lemonade
      mole
      netbird
      nmap
      oneshot
      ookla-speedtest
      portal
      qrcp
      qrrs
      rustscan
      sipcalc
      socat
      sshfs
      termshark
      trippy
      upcloud-cli
      warpgate
      websocat
      wireproxy
      xh

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
      cliamp
      dnote
      glow
      gurk-rs
      hugo
      lockbook
      lux
      mdbook
      nom
      presenterm
      russ
      slides
      tectonic
      ticker
      tui-journal
      typst
      zk

      # System inspection
      bottom
      cpufetch
      gotop
      pik
      systemd-manager-tui
      ugm

      # One Python environment keeps these CLI tools and their imports together.
      (python3.withPackages (ps: with ps; [
        aiohttp # blackd's optional daemon dependency
        ansi2html
        black
        dataclass-wizard
        fiona
        numpy
        presenterm-export
        weasyprint
      ]))
    ] ++ (with pkgsUnstable; [
      # These applications are currently absent from the stable package set.
      diskonaut-ng
      qrc
      unifly
    ]) ++ lib.optionals desktop.enable (with pkgs; [
      # Desktop applications and input utilities; services are configured separately.
      bluetuith
      clipse
      daktilo
      devour
      espanso
      evremap
      evsieve
      eww
      f3d
      grobi
      handlr
      haskellPackages.greenclip
      impala
      interception-tools
      kanata
      lan-mouse
      moonlight-qt
      mpd-mpris
      mpvpaper
      ncpamixer
      wdisplays
      wlvncc
      xcolor
      xob
    ]) ++ lib.optionals (desktop.enable && desktop.environment == "hyprland") [
      pkgs.hyprdynamicmonitors
      pkgs.hyprsome
      pkgsUnstable.hyprscratch
    ];
  };
}
