{ lib, fetchurl, morf }:
let
  # Keep following upstream. Until the renderer fixes reach its source, apply
  # the reviewed repair to that source and build the binary/library together.
  # This changes Morf only; the FP6 kernel remains the installed boot artifact.
  shader = builtins.readFile "${morf.src}/crates/graphics/morf-render/src/field.wgsl";
  input = builtins.readFile "${morf.src}/crates/frontend/morf-host/src/input/mod.rs";
  repaired = lib.hasInfix "fn isolated_group(" shader && lib.hasInfix "pub mod two_finger;" input;
  repair = fetchurl {
    url = "https://github.com/paneworks/morf/compare/8ab7a1eede4e18efe15ac02b54169ffafa8403e8...16260a2c75de4bc33a9e730b6bd44cd4c1db5238.diff";
    hash = "sha256-xULdky0IVjaGdcbZIipm9CC5yJ+96ZPSFiyH+S+k5TE=";
  };
in if repaired then morf else morf.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ repair ];
})
