{
  config,
  lib,
  ...
}:
let
  cfg = config.bresilla.programs.prek;
in
{
  options.bresilla.programs.prek = {
    enable = lib.mkEnableOption "Prek touchscreen shortcuts";
    shortcuts = lib.mkOption {
      type = lib.types.str;
      description = "The user's shortcut file, by name, in configs/assets/prek.";
    };
  };

  # Prek owns the touchscreen; Hyprland starts its session agent as a child.
  config = lib.mkIf (cfg.enable && config.programs.hyprland.enable) {
    programs.eva.hyprland.extraConfig = lib.mkAfter ''
      hl.on("hyprland.start", function()
        hl.exec_cmd("${config.services.prek.session.package}/bin/prek-session")
      end)
    '';
    services.prek = {
      enable = true;
      mode = "route";
      allowPhysicalTakeover = true;
      compositorExecutable = "${config.programs.hyprland.package}/bin/.Hyprland-wrapped";
      luaConfig = ''
        local p = require("prek")
        return p.config.new {
            mode = "route",
            policy = { allowed_devices = {"touch"}, allow_runtime_rules = true },
            -- A direct-input multi-touch device: the touchscreen.
            devices = { touch = { properties = {1}, absolute_axes = {53, 54} } },
        }
      '';
      session = {
        commands = true;
        ruleMutations = true;
        shortcuts = "\${XDG_CONFIG_HOME:-$HOME/.config}/prek/${cfg.shortcuts}";
      };
    };
  };
}
