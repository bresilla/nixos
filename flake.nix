{
  description = "Personal NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, disko, ... }:
    let
      mkHost = name: profile: nixpkgs.lib.nixosSystem {
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
