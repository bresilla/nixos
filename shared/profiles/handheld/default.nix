{ lib, ... }:
{
  # A touch handheld with game controls: the shared desktop with Morf's touch
  # gestures, but no modem. Device modules set the panel's rotation and scale.
  imports = [ ../shared.nix ];
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  services.smartd.enable = false;
  bresilla.features.network.cellular.enable = false;
  programs.morf.phone.enable = true;
  programs.morf.phone.gestureDriver = "native";
  bresilla.programs.steamArm64.enable = lib.mkDefault true;
}
