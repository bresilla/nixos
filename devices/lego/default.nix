{ ... }:
{
  imports = [
    ./storage.nix
    ../../device-recipes/lenovo-tb321fu/software/hardware.nix
    ../../device-recipes/lenovo-tb321fu/software/quirks.nix
    ../../device-recipes/lenovo-tb321fu/software/boot.nix
    ../../device-recipes/lenovo-tb321fu/software/usb-gadget.nix
    ../../device-recipes/lenovo-tb321fu/software/display.nix
    ../../device-recipes/lenovo-tb321fu/software/pen.nix
    ../../device-recipes/lenovo-tb321fu/software/audio.nix
    ../../device-recipes/lenovo-tb321fu/software/suspend.nix
    ../../device-recipes/lenovo-tb321fu/software/battery-log.nix
  ];
  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "lego";
  bresilla.nix.buildOnTron = true;
}
