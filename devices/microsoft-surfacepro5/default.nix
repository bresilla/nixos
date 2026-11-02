{ ... }:
{
  imports = [
    ../../device-recipes/microsoft-surfacepro5/software/hardware.nix
    ./storage.nix
    ../shared/uefi.nix
    "${import ../../device-recipes/microsoft-surfacepro5/software/nixos-hardware.nix}/microsoft/surface/surface-pro-intel"
  ];
  networking.hostName = "surf";

  # Ignore every touchscreen contact while the pen is in proximity, including hover.
  bresilla.programs.iptsd.enable = true;
  services.iptsd.config.Touchscreen = {
    DisableOnStylus = true;
    DisableOnStylusDelay = 1000; # Milliseconds after the pen leaves proximity.
  };
}
