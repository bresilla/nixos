{ pkgs, ... }:
{
  # Use Hyprland's workspace renderer with bottom-edge touch recognition.
  # No gesture plugin is loaded. This module is imported by the phone only.
  programs.hyprland.package = pkgs.hyprland.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ../patches/hyprland-bottom-touch.patch ];
  });
}
