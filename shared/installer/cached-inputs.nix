{ system, manifest }:
let
  # Pins for the system being built, which need not be the updating machine's.
  # A system the caches build nothing for yet (riscv64) has none: its pinned tools are
  # null, and the modules that use them leave them out.
  unpinned = manifest != null && !(manifest ? ${system});
  pins = if manifest == null
    then throw "cache-binaries.json is missing: run the updater, which resolves the cache pins"
    else manifest.${system} or { };
  # The updater has fetched and signature-checked these outputs. Keep them as
  # store dependencies without attaching a source-build derivation.
  package = cache: name: if unpinned then null else
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
  # Every system's names, so a pin missing for this one stops with package's message.
  bresilla = builtins.mapAttrs (name: _: package "bresilla" name)
    (builtins.foldl' (all: pinned: all // (pinned.bresilla or { })) { }
      (builtins.attrValues (builtins.seq pins manifest)));
  firmwares = builtins.mapAttrs (name: _: package "firmwares" name)
    (builtins.foldl' (all: pinned: all // (pinned.firmwares or { })) { }
      (builtins.attrValues (builtins.seq pins manifest)));
  aiNerv = nervMissing // builtins.mapAttrs (name: _: package "ai-nerv" name) (pins.ai-nerv or { });
  termworks = builtins.listToAttrs (map (name: { inherit name; value = tool "termworks" name; })
    [ "oslo" "hexe" "drop" "pixy" "lule" "geto" "trek" "wing" "goku" "midy" ]);
  paneworks = { morf = tool "paneworks" "morf"; eva = tool "paneworks" "eva"; };
}
