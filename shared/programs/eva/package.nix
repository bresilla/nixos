{
  lib,
  runCommand,
  roboto,
  material-symbols,
  ibm-plex,
  nerd-fonts,
  src,
  library,
}:
let
  # eva's own version, as morf.lua declares it.
  version = builtins.head (builtins.match ''.*version = "([0-9.]+)".*''
    (builtins.replaceStrings [ "\n" ] [ " " ] (builtins.readFile (src + "/morf.lua"))));
  # Found by name: where a font package puts its files moves between
  # nixpkgs releases.
  fonts = [
    { package = roboto; name = "Roboto-Regular.ttf"; }
    { package = material-symbols; name = "MaterialSymbolsRounded*.ttf"; }
    { package = ibm-plex; name = "IBMPlexMono-Regular.otf"; }
    { package = nerd-fonts."m+"; name = "M+1NerdFont-Regular.ttf"; }
    { package = nerd-fonts.caskaydia-cove; name = "CaskaydiaCoveNerdFont-Regular.ttf"; }
  ];
in
# The shell, lock screen and greeter as one tree, with the Lua library of the
# morf it runs on and the fonts it draws with.
runCommand "eva-${version}"
  {
    inherit version;
    passthru.fontPackages = map (font: font.package) fonts;
    meta = {
      description = "A desktop shell, lock screen and greeter for morf";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  }
  ''
    mkdir -p "$out"
    for part in shell lock greet themes models lib; do
      cp -R ${src}/$part "$out/"
    done
    cp ${src}/morf.lua "$out/morf.lua"
    chmod -R u+w "$out"
    mkdir -p "$out/library"
    cp -R ${library}/share/morf/library/lib "$out/library/"
    # One fonts folder for all three: the shell's own faces plus the packaged ones.
    mkdir -p "$out/fonts"
    cp -R ${src}/shell/fonts/. "$out/fonts/"
    for part in shell lock greet; do
      rm -rf "$out/$part/fonts"
      ln -s ../fonts "$out/$part/fonts"
    done
    ${lib.concatMapStringsSep "\n" (font: ''
      found=$(find ${font.package}/share/fonts -name ${lib.escapeShellArg font.name} | sort | head -n 1)
      if [ -z "$found" ]; then
        echo "no ${font.name} in ${font.package}" >&2
        exit 1
      fi
      ln -s "$found" "$out/fonts/"
    '') fonts}
  ''
