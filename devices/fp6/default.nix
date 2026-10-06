{ ... }:
{
  imports = [ ./hardware.nix ./device.nix ./morf.nix ./touchscreen.nix ];
  nixpkgs.config.allowUnfree = true;
  bresilla.services.phoneScreen.idleTimeout = 0;
}
