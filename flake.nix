{
  description = "Personal NixOS configurations";

  nixConfig = {
    extra-substituters = [ "https://termworks.cachix.org" ];
    extra-trusted-public-keys = [
      "termworks.cachix.org-1:Ty7sSVALfD5ajbcWBIdaNHcaEx3fEmVrOo+rSzy0mvE="
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
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, disko, oslo, hexe, drop, pixy, lule, geto, trek, wing, ... }:
    let
      mkHost = name: profile: nixpkgs.lib.nixosSystem {
        specialArgs = { termworks = { inherit oslo hexe drop pixy lule geto trek wing; }; };
        modules = [
          disko.nixosModules.disko
          ./configuration.nix
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
