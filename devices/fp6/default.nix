{ ... }:
{
  imports = [ ./hardware.nix ./device.nix ./morf.nix ];
  nixpkgs.config.allowUnfree = true;
}
