{ fp6Inputs, fp6BuildPkgs, ... }:
{
  imports = [ ./hardware.nix ./device.nix ];
  _module.args = {
    inherit (fp6Inputs) fp6-linux fp6-firmware fp6-kernel-config pil-squasher;
  };
  nixpkgs.config.allowUnfree = true;
}
