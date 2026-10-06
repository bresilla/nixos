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
  config.environment.systemPackages = [ config.bresilla.programs.morf.package morf.morf-library ];
}
