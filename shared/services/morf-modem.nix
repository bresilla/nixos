{ config, lib, pkgs, ... }:
let
  repair = name: file: hash: {
    name = "modem_repair/${name}.lua";
    path = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/paneworks/morf/1726c4191920fe0487b2deacf22f0abc3c8b4586/${file}";
      inherit hash;
    };
  };
  runtime = pkgs.linkFarm "morf-mobile-settings" [
    (repair "services" "examples/shells/caelestia/shell/services.lua" "sha256-XKbBtiXTE+id5s81bkK5UEeRidzpQwtqS7qkotw3tOY=")
    (repair "settings_model" "examples/shells/caelestia/shell/settings_model.lua" "sha256-swfpE36DY8XhvHUQ9J1TFKd0lQaLrHM8TTzE1R/F4o0=")
    (repair "bar_model" "examples/shells/caelestia/shell/bar_model.lua" "sha256-qPMPPxOvwGb+VM6OxOXXae2FlRrBi/431xrhAHXm/BE=")
    (repair "utilities" "examples/shells/caelestia/shell/utilities.lua" "sha256-8oGWhmd/sdHRj1kULnH/GtiNS+0ApyWBQhDf+SX6R34=")
    (repair "connectivity" "examples/shells/caelestia/shell/connectivity.lua" "sha256-rB8O4CLYW1QzhpHZhDX/tb6jJvGegxxCun+oACCdr14=")
    (repair "mobile_model" "examples/shells/caelestia/shell/mobile_model.lua" "sha256-xl/TLm8qC8YH0fYAYY4+vxmkXf46hLjU1WwN6PTRrJk=")
    (repair "connectivity_view" "examples/shells/caelestia/themes/layouts/views/connectivity.lua" "sha256-Ud5AMO7xZ0EixEThAey2VEa9GSgI2VsRDdQfOpRYdoE=")
    (repair "modem_service" "library/lib/services/modem.lua" "sha256-5dFXLWhQjvXX6diNIyjtbxmEaSM7kcSTDo15ovcUlfk=")
    (repair "networkmanager_service" "library/lib/services/networkmanager.lua" "sha256-KypGAmqEE0gaYBABVQPvNNcgXRrqYkPkQOB4pkKJDTI=")
    { name = "plugin/00-modem.lua"; path = ./morf-modem-plugin.lua; }
  ];
in {
  options.bresilla.services.morf.runtimePaths = lib.mkOption {
    type = lib.types.listOf lib.types.path;
    default = [];
    description = "Additional Morf desktop modules and startup plugins.";
  };
  config = lib.mkIf config.bresilla.features.desktop.enable {
    # Apply the reviewed mobile settings to existing dotfile checkouts until they update.
    bresilla.services.morf.runtimePaths = lib.mkBefore [ runtime ];
    systemd.user.services.morf.environment.MORF_RUNTIME_PATH =
      lib.concatMapStringsSep ":" toString config.bresilla.services.morf.runtimePaths;
  };
}
