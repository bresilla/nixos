{ config, lib, pkgs, paneworks, ... }:

let
  morf = paneworks.morf.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  options.bresilla.programs.morf.package = lib.mkOption {
    type = lib.types.package;
    default = morf.morf;
    description = "Morf executable shared by the desktop, greeter and lock screen.";
  };
  options.bresilla.programs.morf.libraryPackage = lib.mkOption {
    type = lib.types.package;
    default = config.bresilla.programs.morf.package.library or morf.morf-library;
    description = "Lua library matching the selected Morf executable.";
  };
  config.environment.systemPackages = [
    config.bresilla.programs.morf.package
    config.bresilla.programs.morf.libraryPackage
  ];
}
