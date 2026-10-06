{ pkgs, paneworks, ... }:
{
  # These renderer changes include Rust code, so an embedded-shader replacement
  # is no longer sufficient. Use the upstream derivation with a reviewed patch
  # until the fixes are published; Nix can reuse matching cached builds later.
  bresilla.programs.morf.package = pkgs.callPackage ./morf-package.nix {
    morf = (paneworks.morf.sourcePackages or paneworks.morf.packages).${pkgs.stdenv.hostPlatform.system}.morf;
  };
}
