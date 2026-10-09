{
  description = "Packages not in nixpkgs, or built differently, served from bresilla.cachix.org";

  # Its own lock, so CI and every machine agree on the exact store paths.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          freerdp = pkgs.callPackage ./freerdp.nix { };
        }
      );
    };
}
