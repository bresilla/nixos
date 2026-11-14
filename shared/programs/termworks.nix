{ pkgs, termworks, ... }:

{
  # Null where the cache has no build for this system (riscv64).
  environment.systemPackages = builtins.filter (p: p != null) (map
    (input: input.packages.${pkgs.stdenv.hostPlatform.system}.default)
    (builtins.attrValues termworks));

  fonts.packages = builtins.filter (p: p != null) [ termworks.goku.packages.${pkgs.stdenv.hostPlatform.system}.goku ];
  fonts.fontconfig.defaultFonts.monospace = [ "Goku" ];
  # The portable Alacritty config still requests its original Gohu family.
  # Prefer Goku on NixOS without rewriting the editable dotfiles checkout.
  fonts.fontconfig.localConf = ''
    <alias binding="strong">
      <family>GohuFont 14 Nerd Font Mono</family>
      <prefer><family>Goku</family></prefer>
    </alias>
  '';
}
