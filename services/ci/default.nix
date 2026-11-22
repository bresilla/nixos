let
  release = builtins.fromJSON (builtins.readFile ./muros-release.json);
  pinned = system: name: path: {
    type = "derivation";
    inherit name;
    outPath = builtins.appendContext path { ${path} = { path = true; }; };
    outputName = "out";
    outputs = [ "out" ];
    meta.platforms = [ system ];
  };
  package = pinned release.system "muros-${release.version}" release.path;
in import ./hive-ci.nix {
  murosPackage = package;
  murosModule = import ./murosd.nix {
    packages.${release.system} = {
      muros = package;
      muros-probe = pinned release.system "muros-worker-probe.nix" release.probe;
    };
  };
  forgeModule = import ./forge.nix { packages.${release.system}.muros = package; };
  stepPackages = builtins.mapAttrs (system: pinned system "muros-static-${system}") release.steps;
  cacheDefinitions = builtins.attrValues (builtins.fromJSON (builtins.readFile ../../shared/caches.json));
  responseHeaders = import ../headers.nix;
}
