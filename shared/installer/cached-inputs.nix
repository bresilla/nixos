{ system, manifest }:
let
  # Pins for the system being built, which need not be the updating machine's.
  pins = if manifest == null
    then throw "cache-binaries.json is missing: run the updater, which resolves the cache pins"
    else manifest.${system} or (throw "cache-binaries.json has no pins for ${system}");
  # The updater has fetched and signature-checked these outputs. Keep them as
  # store dependencies without attaching a source-build derivation.
  package = cache: name:
    let path = pins.${cache}.${name} or (throw
      "No cached ${name} for ${system} on cache.bresilla.com; a missing binary stops the update instead of compiling");
    in assert builtins.match "/nix/store/[a-z0-9]{32}-[^/]+" path != null; {
      type = "derivation";
      name = builtins.substring 33 (-1) (baseNameOf path);
      outPath = builtins.appendContext path { ${path} = { path = true; }; };
      outputName = "out";
      outputs = [ "out" ];
      meta.platforms = [ system ];
    };
  # Shaped like a flake input, so modules keep reading `<tool>.packages.<system>.<name>`.
  tool = cache: name: {
    packages.${system} = { default = package cache name; ${name} = package cache name; };
  };
  # ai-nerv tools come only from pins; without one they are null, not missing.
  nervMissing = builtins.listToAttrs (map (name: { inherit name; value = null; })
    [ "magi" "casper" "melchior" "balthasar" ]);
in {
  bresilla = builtins.mapAttrs (name: _: package "bresilla" name) (pins.bresilla or { });
  aiNerv = nervMissing // builtins.mapAttrs (name: _: package "ai-nerv" name) (pins.ai-nerv or { });
  termworks = builtins.listToAttrs (map (name: { inherit name; value = tool "termworks" name; })
    [ "oslo" "hexe" "drop" "pixy" "lule" "geto" "trek" "wing" "goku" ]);
  paneworks.morf.packages.${system} = {
    default = package "paneworks" "morf";
    morf = package "paneworks" "morf";
    morf-library = package "paneworks" "morf-library";
  };
}
