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
  # eva runs on the pinned morf from cache.bresilla.com.
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
