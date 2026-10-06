{ ... }:
{
  imports = [ ./hardware.nix ./device.nix ./morf.nix ./touchscreen.nix ];
  nixpkgs.config.allowUnfree = true;
}
