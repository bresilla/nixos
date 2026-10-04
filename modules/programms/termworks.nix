{ pkgs, termworks, ... }:

{
  environment.systemPackages = map
    (input: input.packages.${pkgs.stdenv.hostPlatform.system}.default)
    (builtins.attrValues termworks);
}
