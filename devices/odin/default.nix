{ ... }:
{
  imports = [
    ./storage.nix
    ../../device-recipes/ayn-odin3/software/hardware.nix
    ../../device-recipes/ayn-odin3/software/quirks.nix
    ../../device-recipes/ayn-odin3/software/boot.nix
    ../../device-recipes/ayn-odin3/software/fan.nix
    ../../device-recipes/ayn-odin3/software/usb-gadget.nix
    ../../device-recipes/ayn-odin3/software/display.nix
    ../../device-recipes/ayn-odin3/software/audio.nix
    ../../device-recipes/ayn-odin3/software/suspend.nix
  ];
  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "odin";
  bresilla.nix.buildOnTron = true;
}
