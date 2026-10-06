{ pkgs, paneworks, ... }:
{
  # Keep following the current cached package. Until the upstream render fix
  # is released, repair its known shader without compiling Morf or the kernel.
  bresilla.programs.morf.package = pkgs.callPackage ./morf-package.nix {
    morf = paneworks.morf.packages.${pkgs.stdenv.hostPlatform.system}.morf;
  };
}
