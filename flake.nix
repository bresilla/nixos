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
    # Keep Oslo's own locked inputs so the package matches the Cachix build.
    oslo.url = "github:termworks/oslo/292742ba6ff4aa4bd7593cb85e42481334277c8c";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, disko, oslo, ... }:
    let
      mkHost = name: profile: nixpkgs.lib.nixosSystem {
        specialArgs = { inherit oslo; };
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
