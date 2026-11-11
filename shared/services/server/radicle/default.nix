{ pkgs, domain }:

let
  siteUi = import ../ui { inherit pkgs; };
  headerStyle = pkgs.writeText "radicle-header.css" (builtins.replaceStrings
    [ "@HEADER@ svg" "@HEADER@ nav" "@HEADER@" ]
    [ ".header-container > .site-logo" ".header-container .site-navigation" ".header-container" ]
    (builtins.readFile ../ui/header.css));
  assetVersion = builtins.substring 0 12 (builtins.hashString "sha256"
    (toString siteUi + toString headerStyle
      + builtins.readFile ./theme.css + builtins.readFile ./theme.js
      + builtins.readFile ./header.svelte + builtins.readFile ./adapt.py));
  explorer = pkgs.radicle-explorer.withConfig {
    nodes.homepage = "node";
    preferredSeeds = [{ hostname = domain; port = 443; scheme = "https"; }];
  };
in
explorer.overrideAttrs (previous: {
  nativeBuildInputs = (previous.nativeBuildInputs or []) ++ [ pkgs.python3 ];
  postPatch = (previous.postPatch or "") + ''
    install -Dm644 ${siteUi}/logo-black.svg public/bresilla/logo.svg
    cp ${siteUi}/{tokens.css,theme.js} public/bresilla/
    cat ${headerStyle} ${./theme.css} > public/bresilla/explorer.css
    cp ${./theme.js} public/bresilla/explorer.js

    substituteInPlace index.html \
      --replace-fail '<title>Radicle Explorer</title>' '<title>Radicle · bresilla</title>' \
      --replace-fail 'href="/typography.css"' 'href="/typography.css?v=${assetVersion}"' \
      --replace-fail '<link rel="icon" href="/favicon.png" type="image/png" />' \
        '<link rel="stylesheet" href="/bresilla/tokens.css?v=${assetVersion}" />
         <link rel="stylesheet" href="/bresilla/explorer.css?v=${assetVersion}" />
         <link rel="icon" href="/bresilla/logo.svg" type="image/svg+xml" />
         <script src="/bresilla/theme.js?v=${assetVersion}"></script>
         <script src="/bresilla/explorer.js?v=${assetVersion}"></script>'

    python ${./adapt.py} header ${./header.svelte}
    substituteInPlace src/components/Header.svelte public/bresilla/explorer.js \
      --replace-fail '/bresilla/logo.svg' '/bresilla/logo.svg?v=${assetVersion}'

    substituteInPlace public/typography.css \
      --replace-fail 'Booton, sans-serif' 'var(--site-font), Booton, sans-serif' \
      --replace-fail '"JetBrains Mono", monospace' 'var(--site-code-font), "JetBrains Mono", monospace'
  '';
  postBuild = (previous.postBuild or "") + ''
    python ${./adapt.py} styles '<link rel="stylesheet" href="/bresilla/explorer.css?v=${assetVersion}" />'
  '';
})
