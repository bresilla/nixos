{
  description = "Explicit FP6 kernel builds, from the pinned recipe in ../kernel";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  outputs = { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
    in {
      packages = lib.genAttrs systems (system:
        let
          fp6 = import ../kernel { buildSystem = system; };
        in {
          inherit (fp6) kernel;
          default = fp6.kernel;
        });
      devShells = lib.genAttrs systems (system: {
        default = import ./shell.nix { pkgs = nixpkgs.legacyPackages.${system}; };
      });
    };
}
