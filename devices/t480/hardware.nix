{ modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ../lib/uefi.nix
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
}
