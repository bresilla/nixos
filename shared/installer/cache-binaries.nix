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
in {
  inherit system;
  termworks = resolve (builtins.getEnv "CACHIX_TERMWORKS_PINS")
    [ "oslo" "hexe" "drop" "pixy" "lule" "geto" "trek" "wing" "goku" ];
  paneworks = resolve (builtins.getEnv "CACHIX_PANEWORKS_PINS") [ "morf" "morf-library" ];
}
