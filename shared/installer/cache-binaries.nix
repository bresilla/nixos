let
  system = builtins.getEnv "CACHIX_SYSTEM";
  resolve = file: names:
    let pins = builtins.fromJSON (builtins.readFile file);
    in builtins.listToAttrs (map (name:
      let
        pinName = "${name}-${system}";
        matches = builtins.filter (pin: pin.name == pinName) pins;
        path = (builtins.head matches).lastRevision.storePath;
        packagePattern = if name == "morf-library" then "morf-[^/]+-library" else "${name}-[^/]+";
      in {
        inherit name;
        value = if builtins.length matches != 1 then
          throw "Missing or ambiguous Cachix pin: ${pinName}"
        else if builtins.match "/nix/store/[a-z0-9]{32}-${packagePattern}" path == null then
          throw "Invalid store path for Cachix pin: ${pinName}"
        else path;
      }) names);
  # Every `<package>-<system>` pin; a package without one keeps nixpkgs' build.
  resolveAll = file:
    let
      suffix = "-${system}";
      pins = builtins.filter (pin: builtins.match ".+${suffix}" pin.name != null)
        (builtins.fromJSON (builtins.readFile file));
      named = map (pin: rec {
        name = builtins.substring 0 (builtins.stringLength pin.name - builtins.stringLength suffix) pin.name;
        value = let path = pin.lastRevision.storePath; in
          if builtins.match "/nix/store/[a-z0-9]{32}-${name}-[^/]+" path == null
          then throw "Invalid store path for Cachix pin: ${pin.name}" else path;
      }) pins;
    in builtins.listToAttrs named;
in {
  inherit system;
  termworks = resolve (builtins.getEnv "CACHIX_TERMWORKS_PINS")
    [ "oslo" "hexe" "drop" "pixy" "lule" "geto" "trek" "wing" "goku" ];
  paneworks = resolve (builtins.getEnv "CACHIX_PANEWORKS_PINS") [ "morf" "morf-library" ];
  bresilla = resolveAll (builtins.getEnv "CACHIX_BRESILLA_PINS");
}
