# RustFS's console rebuilt in the shared look: its own theme hook (themes/<id>)
# takes the manifest, logo and the header components; console.patch puts the
# shared header over every page; the shared tokens go at the end of its CSS.
{ pkgs, console }:
let
  siteUi = import ../ui { inherit pkgs; };
in console.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./console.patch ];
  nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.jq ];
  env = (old.env or { }) // { THEME_ID = "bresilla"; };
  postPatch = (old.postPatch or "") + ''
    t=themes/bresilla
    mkdir -p $t/assets $t/components $t/public
    cp ${./theme/manifest.json} $t/manifest.json
    cp ${siteUi}/logo.svg $t/assets/logo.svg
    cp ${siteUi}/logo.svg $t/assets/logo-dark.svg
    cp ${./theme/components}/*.tsx $t/components/
    logo=$(sed '1{/^<?xml/d}' ${siteUi}/logo.svg \
      | sed -E 's/fill="#[0-9a-fA-F]+"/fill="currentColor"/g' | jq -Rs .)
    printf 'export const SITE_LOGO: string = %s\n' "$logo" > $t/components/site-logo.ts
    substitute ${./theme/adapter.js} adapter.js --replace-fail @LOGO@ "$logo"
    cat ${siteUi}/theme.js adapter.js > $t/public/bresilla.js
    cat ${siteUi}/tokens.css ${siteUi}/id-header.css ${./theme/console.css} >> app/globals.css
  '';
})
