{ ... }:
{
  imports = [
    ./storage.nix
    ../../device-recipes/fairphone-fp6/software/hardware.nix
    ../../device-recipes/fairphone-fp6/software/network.nix
    ../../device-recipes/fairphone-fp6/software/display.nix
    ../../device-recipes/fairphone-fp6/software/touchscreen.nix
    ../../device-recipes/fairphone-fp6/software/rotation.nix
    ../../device-recipes/fairphone-fp6/software/audio.nix
    ../../device-recipes/fairphone-fp6/software/modem.nix
    ../../device-recipes/fairphone-fp6/software/calls.nix
    ../../device-recipes/fairphone-fp6/software/fingerprint.nix
    ../../device-recipes/fairphone-fp6/software/gaming.nix
    ../../device-recipes/fairphone-fp6/software/battery-log.nix
    ../../device-recipes/fairphone-fp6/software/suspend.nix
  ];
  nixpkgs.config.allowUnfree = true;
  programs.eva.phone.idleTimeout = 0;
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "fair";
  bresilla.nix.buildOnTron = true;
}
