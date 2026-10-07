{ config, lib, pkgs, ... }:
let
  repair = file: hash: {
    name = "modem_repair/${file}.lua";
    path = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/paneworks/morf/13c178b35248ca56f3cd6ee35693ea9c2a5fd1af/examples/shells/caelestia/shell/${file}.lua";
      inherit hash;
    };
  };
  runtime = pkgs.linkFarm "morf-modem-observer" [
    (repair "services" "sha256-XKbBtiXTE+id5s81bkK5UEeRidzpQwtqS7qkotw3tOY=")
    (repair "settings_model" "sha256-33mBRuvCqvAl3BGpiZYLS7J0WojOzXQfSzDbo4GNi/k=")
    (repair "bar_model" "sha256-qPMPPxOvwGb+VM6OxOXXae2FlRrBi/431xrhAHXm/BE=")
    { name = "plugin/00-modem.lua"; path = ./morf-modem-plugin.lua; }
  ];
in {
  options.bresilla.services.morf.runtimePaths = lib.mkOption {
    type = lib.types.listOf lib.types.path;
    default = [];
    description = "Additional Morf desktop modules and startup plugins.";
  };
  config = lib.mkIf config.bresilla.features.desktop.enable {
    # Apply the reviewed Lua fix to existing dotfile checkouts until they update.
    bresilla.services.morf.runtimePaths = lib.mkBefore [ runtime ];
    systemd.user.services.morf.environment.MORF_RUNTIME_PATH =
      lib.concatMapStringsSep ":" toString config.bresilla.services.morf.runtimePaths;
  };
}
