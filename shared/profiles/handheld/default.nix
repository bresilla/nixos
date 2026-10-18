{ config, lib, pkgs, bresilla, ... }:
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
  bresilla.programs.steamArm64.session.enable = lib.mkDefault true;

  # InputPlumber presents the built-in controls as one standard gamepad for
  # Steam. packages/ builds the release with the AYN Odin 3 profile on Cachix.
  services.inputplumber = {
    enable = true;
    package = (bresilla.inputplumber or pkgs.inputplumber) // {
      meta.mainProgram = "inputplumber";
    };
  };
  # It finds its device profiles through XDG_DATA_DIRS; the module points it at
  # the system profile, which does not link share/inputplumber.
  systemd.services.inputplumber.environment.XDG_DATA_DIRS =
    lib.mkForce "${config.services.inputplumber.package}/share";
}
