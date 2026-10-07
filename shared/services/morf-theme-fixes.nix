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
    url = "https://raw.githubusercontent.com/paneworks/morf/d55276db2563ee520b55f04bf8cf1a5ac7e143eb/examples/shells/caelestia/themes/ui_scale.lua";
    hash = "sha256-GfmDuDkhUp9s+FBwilUcwRU2Dr082zVLj8iPSAUgto4=";
  };
  "shell/phone_gestures.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/e9af2ea5c12883ab108fd24672583010426108ef/examples/shells/caelestia/shell/phone_gestures.lua";
    hash = "sha256-rE1cwEAKyQV0jE9b7HNG/vMzN4gLgnKsMEj7yyNFsnk=";
  };
  "shell/keyboard_gestures.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/e9af2ea5c12883ab108fd24672583010426108ef/examples/shells/caelestia/shell/keyboard_gestures.lua";
    hash = "sha256-OpcJs/9eEvYLRM/V6pCS9427H3ujq4eVfQYpmqX4oGE=";
  };
  "themes/layouts/views/keyboard.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/e9af2ea5c12883ab108fd24672583010426108ef/examples/shells/caelestia/themes/layouts/views/keyboard.lua";
    hash = "sha256-fJ/m8fXfe96EbsTOiC0ARcC/ifRO8VVet3VBHc4tH68=";
  };
  "shell/touch_contacts.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/e9af2ea5c12883ab108fd24672583010426108ef/examples/shells/caelestia/shell/touch_contacts.lua";
    hash = "sha256-8gV9HadCp1NePGmdR7+UKvRwjKKkT4wa1YsASAQ0rng=";
  };
  "shell/workspace_gesture.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/d55276db2563ee520b55f04bf8cf1a5ac7e143eb/examples/shells/caelestia/shell/workspace_gesture.lua";
    hash = "sha256-A5O7MwAMJxfAnlzvVquFiYEzU9Um3jPBdJK2vagFojA=";
  };
  "shell/lib/util/osk.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/e9af2ea5c12883ab108fd24672583010426108ef/library/lib/util/osk.lua";
    hash = "sha256-N8zio/785H//B7tkjHI2AT2m8l6vosw1lrAjMYWP6+w=";
  };
  "shell/init.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/2efe357b997784ed2612e26e6d2032cdf0102905/examples/shells/caelestia/shell/init.lua";
    hash = "sha256-HSs8qJ9fwMCUt9cVwNKY2x07OX0YOpsS6QQEimbAW/4=";
  };
}
