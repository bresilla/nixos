let
  release = builtins.fromJSON (builtins.readFile ./muros-release.json);
  package = {
    type = "derivation";
    name = "muros-${release.version}";
    outPath = builtins.appendContext release.path { ${release.path} = { path = true; }; };
    outputName = "out";
    outputs = [ "out" ];
    meta.platforms = [ release.system ];
  };
in import ./hive-ci.nix {
  murosPackage = package;
  murosModule = import ./murosd.nix { packages.${release.system}.muros = package; };
  cacheDefinitions = builtins.attrValues (builtins.fromJSON (builtins.readFile ../../../caches.json));
  responseHeaders = import ../headers.nix;
}
