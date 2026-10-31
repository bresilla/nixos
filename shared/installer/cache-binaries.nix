let
  host = builtins.getEnv "CACHIX_SYSTEM";
  # Pins for every system, so cross-architecture builds (an aarch64 image built
  # on x86_64) use the cached binaries too. Only the host's must all exist.
  systems = [ "x86_64-linux" "aarch64-linux" ];
  resolve = system: file: names:
    let pins = builtins.fromJSON (builtins.readFile file);
    in builtins.listToAttrs (builtins.concatMap (name:
      let
        pinName = "${name}-${system}";
        matches = builtins.filter (pin: pin.name == pinName) pins;
        path = (builtins.head matches).lastRevision.storePath;
        packagePattern = if name == "morf-library" then "morf-[^/]+-library" else "${name}-[^/]+";
      in
        if builtins.length matches != 1 then
          (if system == host then throw "Missing or ambiguous Cachix pin: ${pinName}" else [ ])
        else [ {
          inherit name;
          value = if builtins.match "/nix/store/[a-z0-9]{32}-${packagePattern}" path == null
            then throw "Invalid store path for Cachix pin: ${pinName}" else path;
        } ]) names);
  # Every `<package>-<system>` pin; a package without one keeps nixpkgs' build.
  resolveAll = system: file:
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
  # packages/pins.json, written by the packages workflow: { <system> = { <name> = <path>; }; }.
  fromFile = system: file:
    let pins = if builtins.pathExists file
      then (builtins.fromJSON (builtins.readFile file)).${system} or { } else { };
    in builtins.mapAttrs (name: path:
      # A script package (the wifiman CLI) has no version in its name.
      if builtins.match "/nix/store/[a-z0-9]{32}-${name}(-[^/]+)?" path == null
      then throw "Invalid store path for pin: ${name}-${system}" else path) pins;
in builtins.listToAttrs (map (system: {
  name = system;
  value = {
    termworks = resolve system (builtins.getEnv "CACHIX_TERMWORKS_PINS")
      [ "oslo" "hexe" "drop" "pixy" "lule" "geto" "trek" "wing" "goku" ];
    paneworks = resolve system (builtins.getEnv "CACHIX_PANEWORKS_PINS") [ "morf" "morf-library" ];
    bresilla = fromFile system (builtins.getEnv "BRESILLA_PINS");
    # The shared pin list holds every project; keep ai-nerv's own, any that exist.
    ai-nerv = builtins.intersectAttrs
      (builtins.listToAttrs (map (name: { inherit name; value = null; })
        [ "balthasar" "casper" "magi" "melchior" ]))
      (resolveAll system (builtins.getEnv "CACHIX_AI_NERV_PINS"));
  };
}) systems)
