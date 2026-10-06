{ ... }:
{
  imports = [ ./hardware.nix ./device.nix ];
  nixpkgs.config.allowUnfree = true;
}
