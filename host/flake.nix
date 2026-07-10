{
  description = "Reusable NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    # The Rust crate (nox) lives at the repo root, one level above this flake.
    crate = {
      url = "path:..";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      disko,
      sops-nix,
      crate,
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
              ./modules/programms/bin.nix
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
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f system);
      pkgsFor = system: import nixpkgs { inherit system; };
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

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          nox = pkgs.callPackage "${crate}/package.nix" {
            disko = disko.packages.${system}.disko;
          };
          # Fully static, self-contained binary for GitHub releases: YubiKey/pcsclite
          # linked statically, no disko wrapper (single portable file). The static
          # pcsclite build fails to populate its `doc`/`man` outputs, so drop them.
          nox-static = pkgs.pkgsStatic.callPackage "${crate}/package.nix" {
            wrapDisko = false;
            pcsclite = pkgs.pkgsStatic.pcsclite.overrideAttrs (old: {
              outputs = builtins.filter (o: o != "doc" && o != "man") old.outputs;
            });
          };
        in
        {
          inherit nox nox-static;
          default = nox;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.cargo
              pkgs.rustc
              pkgs.rustfmt
              pkgs.clippy
              pkgs.pkg-config
              pkgs.pcsclite
              pkgs.cmake
            ];
          };
        }
      );
    };
}
