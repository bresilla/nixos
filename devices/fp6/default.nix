{ ... }:
{
  imports = [ ./hardware.nix ./device.nix ./morf.nix ./touchscreen.nix ./modem.nix ];
  nixpkgs.config.allowUnfree = true;
  bresilla.services.phoneScreen.idleTimeout = 0;
  bresilla.services.morf.uiScale = 1.8;
}
