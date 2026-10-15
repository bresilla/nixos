{
  description = "Packages not in nixpkgs, or built differently, served from bresilla.cachix.org";

  # Its own lock, so CI and every machine agree on the exact store paths.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  # RDP server for Hyprland, built from its own flake at a release tag.
  inputs.hypr-rdp = {
    url = "github:MuNeNiCK/hypr-rdp/v0.1.6";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, hypr-rdp, ... }:
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
        # Upstream builds for x86_64 only.
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          hypr-rdp = hypr-rdp.packages.${system}.hypr-rdp;
        }
      );
    };
}
