{ pkgs }:
{
  "greet/init.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/16260a2c75de4bc33a9e730b6bd44cd4c1db5238/examples/shells/caelestia/greet/init.lua";
    hash = "sha256-b5UcTWb/5k0NP1ONWmuUcOqORrtLjZ/hA4DDeoC9RRA=";
  };
  "lock/init.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/16260a2c75de4bc33a9e730b6bd44cd4c1db5238/examples/shells/caelestia/lock/init.lua";
    hash = "sha256-zV19bG/eH2fvjceld/EWN3WPvhsis4uge2DuXJpM6FQ=";
  };
  "shell/config.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/16260a2c75de4bc33a9e730b6bd44cd4c1db5238/examples/shells/caelestia/shell/config.lua";
    hash = "sha256-mQF0NVcxjMCi77ObKcLNt7Ed14scgH72MthyAoTlg4g=";
  };
  "themes/auth_metrics.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/16260a2c75de4bc33a9e730b6bd44cd4c1db5238/examples/shells/caelestia/themes/auth_metrics.lua";
    hash = "sha256-ux0Whlh42fh1hAoQLR+OFsGs9RL4j6RN4cvdsY9VEYs=";
  };
  "themes/ui_scale.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/16260a2c75de4bc33a9e730b6bd44cd4c1db5238/examples/shells/caelestia/themes/ui_scale.lua";
    hash = "sha256-vS5X8q+x94k6vOV6Dg7jR8ksDZkhNwu2DHtmQeDKtPU=";
  };
  "shell/phone_gestures.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/16260a2c75de4bc33a9e730b6bd44cd4c1db5238/examples/shells/caelestia/shell/phone_gestures.lua";
    hash = "sha256-gZogr8Xr/PXXOyrRpQHjnlNZ9NnTY1HCdjjZXIqoQWs=";
  };
  "shell/keyboard_gestures.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/16260a2c75de4bc33a9e730b6bd44cd4c1db5238/examples/shells/caelestia/shell/keyboard_gestures.lua";
    hash = "sha256-xmehVzn0p5wZfg9lltcBg1y75jKV4qUSv1ZCAHaQtBc=";
  };
  "themes/layouts/views/keyboard.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/16260a2c75de4bc33a9e730b6bd44cd4c1db5238/examples/shells/caelestia/themes/layouts/views/keyboard.lua";
    hash = "sha256-Gzo2xlVWUqrwHaFeFx+IxP7WT+D4n5oFmuXCMXMEa2Q=";
  };
}
