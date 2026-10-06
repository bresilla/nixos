{ pkgs, paneworks, ... }:

let
  morf = paneworks.morf.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  environment.systemPackages = [ morf.morf morf.morf-library ];
}
