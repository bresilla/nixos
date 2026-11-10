{ pkgs }:
let
  tokens = builtins.fromJSON (builtins.readFile ./tokens.json);
  style = ":root {\n" + pkgs.lib.concatStringsSep "\n"
    (pkgs.lib.mapAttrsToList (name: value: "  --site-${name}: ${value};") tokens) + "\n}\n";
  script = builtins.replaceStrings [ "@TOKENS@" "@HEADER@" ]
    [ (builtins.toJSON tokens) (builtins.toJSON (builtins.readFile ./header.html)) ]
    (builtins.readFile ./theme.js);
  header = selector: builtins.replaceStrings [ "@HEADER@" ] [ selector ] (builtins.readFile ./header.css);
in pkgs.runCommand "bresilla-site-ui" { } ''
  mkdir -p $out
  cp ${./site_ui.py} $out/site_ui.py
  cp ${./base.css} $out/base.css
  cp ${./header.html} $out/header.html
  cp ${./icons.json} $out/icons.json
  cp ${../../../../configs/assets/bresilla.svg} $out/logo.svg
  cp ${pkgs.writeText "site-tokens.css" style} $out/tokens.css
  cp ${pkgs.writeText "site-header.css" (header "header")} $out/header.css
  cp ${pkgs.writeText "site-id-header.css" (header "header.site")} $out/id-header.css
  cp ${pkgs.writeText "site-theme.js" script} $out/theme.js
  sed -E 's/fill="#[0-9a-fA-F]+"/fill="#1a1a1a"/g' $out/logo.svg > $out/logo-black.svg
''
