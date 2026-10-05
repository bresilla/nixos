{
  description = "Personal NixOS configurations";

  nixConfig = {
    extra-substituters = [
      "https://termworks.cachix.org"
      "https://paneworks.cachix.org"
    ];
    extra-trusted-public-keys = [
      "termworks.cachix.org-1:Ty7sSVALfD5ajbcWBIdaNHcaEx3fEmVrOo+rSzy0mvE="
      "paneworks.cachix.org-1:5XAOHaQHgDEM4dL1Cpu56zcKZxUWYP7zmv8GD3Siy0Q="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Keep each upstream lock so these packages match the Cachix builds.
    oslo.url = "github:termworks/oslo";
    hexe.url = "github:termworks/hexe";
    drop.url = "github:termworks/drop";
    pixy.url = "github:termworks/pixy";
    lule.url = "github:termworks/lule";
    geto.url = "github:termworks/geto";
    trek.url = "github:termworks/trek";
    wing.url = "github:termworks/wing";
    goku.url = "github:termworks/goku";
    morf.url = "github:paneworks/morf";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, disko, home-manager, oslo, hexe, drop, pixy, lule, geto, trek, wing, goku, morf, ... }:
    let
      mkHost = name: profile: nixpkgs.lib.nixosSystem {
        specialArgs = {
          termworks = { inherit oslo hexe drop pixy lule geto trek wing goku; };
          paneworks = { inherit morf; };
        };
        modules = [
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          ./configuration.nix
          ./modules/home.nix
          profile
          {
            nixpkgs.hostPlatform = nixpkgs.lib.mkDefault "x86_64-linux";
            networking.hostName = nixpkgs.lib.mkDefault name;
          }
        ];
      };
    in {
      nixosConfigurations = {
        laptop = mkHost "laptop" ./modules/profiles/laptop.nix;
        server = mkHost "server" ./modules/profiles/server.nix;
      };
    };
}
