{
  config,
  pkgs,
  termworks,
  paneworks,
  lib,
  ...
}:
let
  user = config.bresilla.user.name;
in
{
  # eva and the morf it runs on are pinned on cache.bresilla.com.
  programs.eva = {
    inherit user;
    lulePackage = termworks.lule.packages.${pkgs.stdenv.hostPlatform.system}.default;
    wallpaperLogo = "${config.users.users.${user}.home}/.bresilla/logo.svg";
  };
  # Nothing where eva has no cached build (riscv64).
  environment.systemPackages = lib.optional
    (paneworks.eva.packages.${pkgs.stdenv.hostPlatform.system}.eva != null) config.programs.eva.package;
}
