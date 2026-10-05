{ config, lib, pkgs, paneworks, ... }:

let
  morf = paneworks.morf.packages.${pkgs.stdenv.hostPlatform.system}.morf;
  greeterFonts = with pkgs; [ roboto material-symbols ibm-plex nerd-fonts."m+" ];
  fontFiles = [
    "${pkgs.roboto}/share/fonts/truetype/Roboto-Regular.ttf"
    "${pkgs.material-symbols}/share/fonts/truetype/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf"
    "${pkgs.ibm-plex}/share/fonts/opentype/IBMPlexMono-Regular.otf"
    "${pkgs.nerd-fonts."m+"}/share/fonts/truetype/NerdFonts/M+/M+1NerdFont-Regular.ttf"
  ];
  caelestiaConfig = pkgs.runCommand "morf-caelestia" { } ''
    mkdir -p "$out"
    cp -R ${paneworks.morf}/examples/shells/caelestia/. "$out/"
    chmod -R u+w "$out"
    mkdir -p "$out/fonts"
    for part in shell lock greet; do
      if [ -d "$out/$part/fonts" ]; then
        cp -R "$out/$part/fonts/." "$out/fonts/"
        rm -rf "$out/$part/fonts"
      fi
      cat > "$out/$part/appearance-default.json" <<'EOF'
    { "theme": "tsugumori", "font": "" }
    EOF
      ln -s ../fonts "$out/$part/fonts"
    done
    ${lib.concatMapStringsSep "\n" (font: ''
      test -f ${lib.escapeShellArg font}
      ln -s ${lib.escapeShellArg font} "$out/fonts/"
    '') fontFiles}
  '';
  greeter = pkgs.writeShellScript "morf-greeter" ''
    export PATH=${lib.makeBinPath [ pkgs.systemd pkgs.fontconfig ]}:/run/current-system/sw/bin
    export XDG_CONFIG_DIRS=/etc/xdg
    export XDG_DATA_DIRS=${config.services.displayManager.sessionData.desktops}/share:/run/current-system/sw/share
    exec ${pkgs.cage}/bin/cage -m last -s -- ${morf}/bin/morf greet
  '';
in
lib.mkIf config.bresilla.features.desktop.enable {
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${greeter}";
      user = "greeter";
    };
  };

  users.users.greeter = {
    home = "/var/lib/greetd";
    createHome = true;
  };

  environment.etc."xdg/morf/caelestia".source = caelestiaConfig;
  environment.etc."xdg/morf/default".source = caelestiaConfig;
  environment.etc."greetd/default-session" = lib.mkIf config.programs.hyprland.enable {
    text = if config.programs.hyprland.withUWSM then "hyprland-uwsm\n" else "hyprland\n";
  };
  programs.hyprland.withUWSM = lib.mkIf config.programs.hyprland.enable (lib.mkDefault true);

  systemd.user.services.morf = {
    description = "Morf desktop shell";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session-pre.target" ];
    partOf = [ "graphical-session.target" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig = {
      ExecStart = "${morf}/bin/morf shell";
      Restart = "on-failure";
    };
  };
  security.pam.services.morf-lock = { };
  fonts.packages = greeterFonts;
}
