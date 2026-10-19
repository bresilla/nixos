{
  config,
  pkgs,
  termworks,
  ...
}:
let
  user = config.bresilla.user.name;
in
{
  # The engine and its library are eva's own pinned morf, from the binary cache.
  programs.eva = {
    inherit user;
    lulePackage = termworks.lule.packages.${pkgs.stdenv.hostPlatform.system}.default;
    wallpaperLogo = "${config.users.users.${user}.home}/.bresilla/logo.svg";
  };
  environment.systemPackages = [
    config.programs.eva.package
    config.programs.eva.libraryPackage
  ];
}
