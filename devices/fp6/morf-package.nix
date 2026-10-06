{ lib, fetchurl, morf }:
let
  # Keep following upstream. Until the renderer fixes reach its source, apply
  # the reviewed repair to that source and build the binary/library together.
  # This changes Morf only; the FP6 kernel remains the installed boot artifact.
  shader = builtins.readFile "${morf.src}/crates/graphics/morf-render/src/field.wgsl";
  repaired = lib.hasInfix "fn isolated_group(" shader;
  repair = fetchurl {
    url = "https://github.com/paneworks/morf/compare/8ab7a1eede4e18efe15ac02b54169ffafa8403e8...e9785ba4bfaea583ac41ff688001e48c94f4d011.diff";
    hash = "sha256-j9OGOii7VyqytFtN++L4hQoKomzKI2ez2GylHiox3iA=";
  };
in if repaired then morf else morf.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ repair ];
})
