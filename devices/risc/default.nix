# risc: a StarFive VisionFive 2 Lite, booting from its microSD card.
# cache.nixos.org has nothing for riscv64, so the whole system is cross-compiled on an
# x86_64 builder and cached there: the board never compiles, as no device does.
{ ... }:
{
  imports = [
    ../../device-recipes/starfive-visionfive2lite/software/hardware.nix
    ../../device-recipes/starfive-visionfive2lite/software/boot.nix
  ];
  nixpkgs.buildPlatform = "x86_64-linux";
  networking.hostName = "risc";
}
