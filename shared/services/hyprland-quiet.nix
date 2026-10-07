{ config, lib, pkgs, ... }:
let
  hyprland = config.programs.hyprland.package;
  desktopConfig = pkgs.writeText "hyprland-session.lua" ''
    local apply_scale = dofile("${./hyprland-scale.lua}")(
      ${builtins.toJSON config.bresilla.services.morf.uiScaleFile}, ${toString config.bresilla.services.morf.uiScale})
    local root = (os.getenv("XDG_CONFIG_HOME") or (assert(os.getenv("HOME")) .. "/.config")) .. "/hypr"
    local file = io.open(root .. "/hyprland.lua", "r")
    if file then
      file:close()
      -- require registers the user's file with Hyprland's config watcher.
      package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
      require("hyprland")
    else
      dofile("${hyprland}/share/hypr/hyprland.lua")
    end
    ${builtins.readFile ./hyprland-quiet.lua}
    ${config.bresilla.services.hyprland.extraConfig}
    apply_scale()
  '';
  desktop = pkgs.writeShellScriptBin "hyprland-session" ''
    exec ${pkgs.systemd}/bin/systemd-cat --identifier=hyprland -- \
      ${hyprland}/bin/start-hyprland -- --config /etc/xdg/hypr/session.lua "$@"
  '';
  sessions = pkgs.runCommand "hyprland-quiet-sessions" {
    passthru.providedSessions = hyprland.providedSessions;
  } ''
    mkdir -p "$out/share"
    cp -R ${hyprland}/share/wayland-sessions "$out/share/"
    chmod -R u+w "$out/share/wayland-sessions"
    substituteInPlace "$out/share/wayland-sessions/hyprland.desktop" \
      --replace-fail '${hyprland}/bin/start-hyprland' '${desktop}/bin/hyprland-session'
  '';
in {
  options.bresilla.services.hyprland.extraConfig = lib.mkOption {
    type = lib.types.lines;
    default = "";
    description = "Profile-specific Lua applied after the user's Hyprland configuration.";
  };

  # Keep the standard session names and other installed desktop environments.
  # UWSM starts hyprland.desktop too, so both login paths use the same settings.
  options.services.displayManager.sessionPackages = lib.mkOption {
    apply = packages: if config.programs.hyprland.enable then
      map (package: if package.outPath == hyprland.outPath then sessions else package) packages
      else packages;
  };

  config = lib.mkIf config.programs.hyprland.enable {
    environment.etc."xdg/hypr/session.lua".source = desktopConfig;
    environment.systemPackages = [ desktop (lib.hiPrio sessions) ];
    system.build.hyprlandQuietSessions = sessions;
    system.build.hyprlandSessionConfig = desktopConfig;
  };
}
