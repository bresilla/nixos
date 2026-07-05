{
  description = "Reusable NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      disko,
      sops-nix,
      ...
    }:
    let
      lib = nixpkgs.lib;
      optionalGeneratedModule =
        path:
        if builtins.pathExists path then
          path
        else
          { ... }: { };
      mkGeneratedInstall =
        {
          role,
          system ? "x86_64-linux",
        }:
        lib.nameValuePair "install-${role}-generated" (
          lib.nixosSystem {
            inherit system;
            modules = [
              disko.nixosModules.disko
              sops-nix.nixosModules.sops
              ./modules/common.nix
              ./modules/accounts.nix
              (optionalGeneratedModule ./generated/user.nix)
              ./modules/features.nix
              ./modules/secrets.nix
              ./modules/programms/essential.nix
              ./modules/programms/system.nix
              ./modules/programms/desktop.nix
              ./modules/programms/flatpak.nix
              ./modules/programms/appimage.nix
              ./modules/services/resolver.nix
              ./modules/services/private-hosts.nix
              ./modules/services/netbird.nix
              ./modules/services/tailscale.nix
              ./modules/services/vpn-clients.nix
              ./modules/services/wireguard.nix
              ./modules/services/wur.nix
              ./modules/services/socketcan.nix
              ./modules/profiles/${role}.nix
              (optionalGeneratedModule ./generated/host.nix)
              (optionalGeneratedModule ./specific/configuration.nix)
              (optionalGeneratedModule ./generated/disko.nix)
            ];
          }
        );
    in
    {
      nixosConfigurations = lib.listToAttrs [
        (mkGeneratedInstall {
          role = "laptop";
        })
        (mkGeneratedInstall {
          role = "server";
        })
      ];
    };
}
