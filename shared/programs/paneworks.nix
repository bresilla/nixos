{
  config,
  lib,
  pkgs,
  paneworks,
  termworks,
  ...
}:
let
  packages = paneworks.morf.packages.${pkgs.stdenv.hostPlatform.system};
  user = config.bresilla.user.name;
in
{
  programs.morf = {
    inherit user;
    package = lib.mkDefault packages.morf;
    libraryPackage = lib.mkDefault (config.programs.morf.package.library or packages.morf-library);
    lulePackage = termworks.lule.packages.${pkgs.stdenv.hostPlatform.system}.default;
    wallpaperLogo = "${config.users.users.${user}.home}/.dot/.bresilla/logo.svg";
  };
  environment.systemPackages = [
    config.programs.morf.package
    config.programs.morf.libraryPackage
  ];
}
