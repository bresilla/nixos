{ system, manifest, termworks, paneworks }:
let
  # The updater has fetched and signature-checked these outputs. Keep them as
  # store dependencies without attaching a source-build derivation.
  package = cache: name:
    let path = manifest.${cache}.${name};
    in assert builtins.match "/nix/store/[a-z0-9]{32}-[^/]+" path != null; {
      type = "derivation";
      name = builtins.substring 33 (-1) (baseNameOf path);
      outPath = builtins.appendContext path { ${path} = { path = true; }; };
      outputName = "out";
      outputs = [ "out" ];
      meta.platforms = [ system ];
    };
  # ai-nerv tools come only from pins; without one they are null, not missing.
  nervMissing = builtins.listToAttrs (map (name: { inherit name; value = null; })
    [ "magi" "casper" "melchior" "balthasar" ]);
  replace = input: replacements: input // {
    packages = input.packages // {
      ${system} = input.packages.${system} // replacements;
    };
  };
in
if manifest == null || manifest.system != system then { inherit termworks paneworks; bresilla = { }; aiNerv = nervMissing; }
else {
  bresilla = builtins.mapAttrs (name: _: package "bresilla" name) (manifest.bresilla or { });
  aiNerv = nervMissing // builtins.mapAttrs (name: _: package "ai-nerv" name) (manifest.ai-nerv or { });
  termworks = builtins.mapAttrs (name: input:
    let cached = package "termworks" name;
    in replace input { default = cached; ${name} = cached; }
  ) termworks;
  paneworks.morf = replace paneworks.morf {
    default = package "paneworks" "morf";
    morf = package "paneworks" "morf";
    morf-library = package "paneworks" "morf-library";
  };
}
