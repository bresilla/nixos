{ ... }:
{
  imports = [
    ./hardware.nix
    ./boot.nix
    ./storage.nix
  ];
  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "odin3";
}
