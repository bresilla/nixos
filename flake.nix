{
  # Dev-only shell for building/running/testing the `nox` crate. This is NOT
  # consumed by the installer or the NixOS host config — that lives in ./host
  # (nix build ./host#nox). Keep this flake purely about local development.
  description = "nox — Rust development shell (build/run/test only)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Native tools needed to compile (mirrors ./package.nix).
        nativeDeps = [
          pkgs.pkg-config
          pkgs.cmake
        ];

        # Libraries linked by the crate (the yubikey crate needs pcsclite).
        libDeps = [
          pkgs.pcsclite
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = nativeDeps;
          buildInputs = libDeps;

          packages = [
            pkgs.rustc
            pkgs.cargo
            pkgs.rustfmt
            pkgs.clippy
            pkgs.rust-analyzer
            pkgs.git-cliff
          ];

          # So `cargo run` finds libpcsclite.so at runtime outside a nix build.
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath libDeps;
        };
      }
    );
}
