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
    url = "https://raw.githubusercontent.com/paneworks/morf/ae73f735f8d0abe3201e352e89afe9c54049cc60/examples/shells/caelestia/shell/config.lua";
    hash = "sha256-xvNh10zafEaDiDJaVsA8HtPn8Vcqh4TjQ9btA4HrzQ4=";
  };
  "themes/auth_metrics.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/54d08de0e36a5f3b5700623e707eaeb607bd515e/examples/shells/caelestia/themes/auth_metrics.lua";
    hash = "sha256-zIoCZKXX66jr3iVkZUuDZvlhivQwhKGmU+Ximi1vlGY=";
  };
  "themes/ui_scale.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/54d08de0e36a5f3b5700623e707eaeb607bd515e/examples/shells/caelestia/themes/ui_scale.lua";
    hash = "sha256-/dzpBLnwIigGOmBv05w3emS7hyEdZ0a+4bSSdy4j1V4=";
  };
  "shell/phone_gestures.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/ae73f735f8d0abe3201e352e89afe9c54049cc60/examples/shells/caelestia/shell/phone_gestures.lua";
    hash = "sha256-8m5GTOqXUEsBofefiAh/mlH3Xm0F4lByS3odccpETAY=";
  };
  "shell/keyboard_gestures.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/2b658a2f2df98d328d890289bc39fc6b3c5ac885/examples/shells/caelestia/shell/keyboard_gestures.lua";
    hash = "sha256-DWTxcywV3N8N9lKhVv7NwUsyt4t8NowQHrySBeI4j98=";
  };
  "themes/layouts/views/keyboard.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/924161f7710ee2333fbec03b12146b1779674c7b/examples/shells/caelestia/themes/layouts/views/keyboard.lua";
    hash = "sha256-nTlC3oooztgV3QyKcQpfEJwLXPQangJ5GDXMATIX6u4=";
  };
  "shell/touch_contacts.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/924161f7710ee2333fbec03b12146b1779674c7b/examples/shells/caelestia/shell/touch_contacts.lua";
    hash = "sha256-75FTtdDiJSy9OdyqfD1JlvahzfK8gRd7F2Ali6jLK3A=";
  };
  "shell/workspace_gesture.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/54d08de0e36a5f3b5700623e707eaeb607bd515e/examples/shells/caelestia/shell/workspace_gesture.lua";
    hash = "sha256-ItEzTFNgrEqNsZNLhy42MktGynq7ZwRy/BvOxjuccvI=";
  };
  "lib/util/osk.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/e9af2ea5c12883ab108fd24672583010426108ef/library/lib/util/osk.lua";
    hash = "sha256-N8zio/785H//B7tkjHI2AT2m8l6vosw1lrAjMYWP6+w=";
  };
  "shell/init.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/2efe357b997784ed2612e26e6d2032cdf0102905/examples/shells/caelestia/shell/init.lua";
    hash = "sha256-HSs8qJ9fwMCUt9cVwNKY2x07OX0YOpsS6QQEimbAW/4=";
  };
  "shell/responsive.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/54d08de0e36a5f3b5700623e707eaeb607bd515e/examples/shells/caelestia/shell/responsive.lua";
    hash = "sha256-DzDr8zCI7F3E1ziCmdiFMd6rf8n7iWYqCK5AZftAXCI=";
  };
  "themes/layouts/views/utilities.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/54d08de0e36a5f3b5700623e707eaeb607bd515e/examples/shells/caelestia/themes/layouts/views/utilities.lua";
    hash = "sha256-hoxfTsWGj7TjwOdDKATd8Meh96NkKqOPym7aadfyHWw=";
  };
  "themes/layouts/views/dashboard.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/2b658a2f2df98d328d890289bc39fc6b3c5ac885/examples/shells/caelestia/themes/layouts/views/dashboard.lua";
    hash = "sha256-l66HpQtBuR57jDYGFUVVjq2wfLcWQqwOCw5kJpCQh3g=";
  };
  "themes/layouts/views/side_panel.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/54d08de0e36a5f3b5700623e707eaeb607bd515e/examples/shells/caelestia/themes/layouts/views/side_panel.lua";
    hash = "sha256-CoB/QcyznykKzbjogN5lRQWPDnV5eP8G+cEd2QWlyhc=";
  };
  "themes/keyboard.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/2b658a2f2df98d328d890289bc39fc6b3c5ac885/examples/shells/caelestia/themes/keyboard.lua";
    hash = "sha256-OIQoUca73mu3FbGp9YGWMYMutzyUktGjMCEn/8z1Uvs=";
  };
  "themes/auth_keyboard.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/924161f7710ee2333fbec03b12146b1779674c7b/examples/shells/caelestia/themes/auth_keyboard.lua";
    hash = "sha256-a3TdYg51bXy/bQ34t2JBrTYz2IG22YAH4Htg4jsxmN0=";
  };
  "themes/touch_contacts.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/924161f7710ee2333fbec03b12146b1779674c7b/examples/shells/caelestia/themes/touch_contacts.lua";
    hash = "sha256-8gV9HadCp1NePGmdR7+UKvRwjKKkT4wa1YsASAQ0rng=";
  };
  "themes/layouts/greet.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/924161f7710ee2333fbec03b12146b1779674c7b/examples/shells/caelestia/themes/layouts/greet.lua";
    hash = "sha256-7EaoXy+JfGKPhP6NXoN568onXakbtBVxkGH6o4KNO+w=";
  };
  "themes/layouts/lock.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/924161f7710ee2333fbec03b12146b1779674c7b/examples/shells/caelestia/themes/layouts/lock.lua";
    hash = "sha256-5CB25eMYADq0oXOvLs9cadbfxSLMf79c5vQv8W0ticg=";
  };
  "shell/bar.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/2b658a2f2df98d328d890289bc39fc6b3c5ac885/examples/shells/caelestia/shell/bar.lua";
    hash = "sha256-U86hX6qSm7L2Q/sCaIC57mdjBHb0EomolgMghCz0Shc=";
  };
  "shell/keyboard.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/2b658a2f2df98d328d890289bc39fc6b3c5ac885/examples/shells/caelestia/shell/keyboard.lua";
    hash = "sha256-qg8zUBGRtnyE3ScyfVyA6DgLTaRyKNQSf5YTkP5s9EM=";
  };
  "themes/frame_host.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/2b658a2f2df98d328d890289bc39fc6b3c5ac885/examples/shells/caelestia/themes/frame_host.lua";
    hash = "sha256-dUX3PU38hMw/MMDdKNmuXIxA/xc4I6+VoaC5S267GGU=";
  };
  "themes/layouts/views/dashboard_terminal.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/2b658a2f2df98d328d890289bc39fc6b3c5ac885/examples/shells/caelestia/themes/layouts/views/dashboard_terminal.lua";
    hash = "sha256-KnVrr+2v40DDzKL2zgmCIVEjRfQzd4tpiE5I9tSo3l0=";
  };
  "shell/drawer.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/ae73f735f8d0abe3201e352e89afe9c54049cc60/examples/shells/caelestia/shell/drawer.lua";
    hash = "sha256-gbus1x/kgwKXXhfuwiuwQoYaEpHMG8WlYGi6gHDSJsk=";
  };
  "lib/kit/scroll.lua" = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/paneworks/morf/ae73f735f8d0abe3201e352e89afe9c54049cc60/library/lib/kit/scroll.lua";
    hash = "sha256-CNJkF/NX4ApvJN6KEfph8EQ6jjx0Nz2nfOJrHoT8Cfk=";
  };
}
