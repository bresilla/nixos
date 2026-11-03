{ hyprpaper }:

# The old picture stays on screen until the new one has loaded.
hyprpaper.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./keep-until-loaded.patch ];
})
