{ config, lib, pkgs, ... }:
let
  cfg = config.bresilla.services.morf.greeter;
  hyprland = config.programs.hyprland.package;
  session = pkgs.writeShellScript "morf-greeter-session" ''
    ${cfg.sessionSetup}
    ${config.system.build.morfLauncher}/bin/morf greet
    status=$?
    ${hyprland}/bin/hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 \
      || ${hyprland}/bin/hyprctl dispatch exit >/dev/null 2>&1
    exit "$status"
  '';
  greeterConfig = pkgs.writeText "morf-greeter.lua" ''
    hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
    ${builtins.readFile ./hyprland-quiet.lua}
    hl.config({
      animations = { enabled = false },
      general = { border_size = 0, gaps_in = 0, gaps_out = 0 },
      input = { kb_layout = "us" },
    })
    ${cfg.extraConfig}
    hl.on("hyprland.start", function()
      hl.exec_cmd("${session}")
    end)
  '';
in {
  options.bresilla.services.morf.greeter = {
    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional Lua for the dedicated Hyprland greeter.";
    };
    sessionSetup = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Shell setup before launching Morf in the greeter.";
    };
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Environment variables for the greeter compositor and its children.";
    };
  };

  config = lib.mkIf config.bresilla.features.desktop.enable {
    system.build.morfGreeterConfig = greeterConfig;
    system.build.morfGreeterCompositor = pkgs.writeShellScript "morf-greeter-compositor" ''
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList
        (name: value: "export ${name}=${lib.escapeShellArg value}") cfg.environment)}
      # Capture even early startup messages, while retaining journal diagnostics.
      exec ${pkgs.systemd}/bin/systemd-cat --identifier=morf-greeter -- \
        ${hyprland}/bin/Hyprland --config ${greeterConfig}
    '';
  };
}
