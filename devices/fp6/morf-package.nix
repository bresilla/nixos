{ lib, fetchurl, morf }:
let
  # Keep following upstream. Until the renderer fixes reach its source, apply
  # the reviewed repair to that source and build the binary/library together.
  # This changes Morf only; the FP6 kernel remains the installed boot artifact.
  shader = builtins.readFile "${morf.src}/crates/graphics/morf-render/src/field.wgsl";
  input = builtins.readFile "${morf.src}/crates/frontend/morf-host/src/input/mod.rs";
  # Gesture recognition runs in Lua on this existing repaired engine.
  repaired = lib.hasInfix "fn isolated_group(" shader && lib.hasInfix "pub mod pan;" input;
  repair = fetchurl {
    url = "https://github.com/paneworks/morf/compare/8ab7a1eede4e18efe15ac02b54169ffafa8403e8...24bae346b359badda122b06a1dbecd7189ad80c0.diff";
    hash = "sha256-N87uELzTewkjC/jzcQzQbAhkz7HeNXN8u0kethx9xYg=";
  };
in if repaired then morf else morf.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ repair ];
})
