{ lib, pkgs, artifacts }:
let
  # Context makes these existing outputs dependencies of the new generation,
  # retaining them through GC without introducing a kernel build derivation.
  storeOutput = path:
    assert builtins.match "/nix/store/[a-z0-9]{32}-[^/]+" path != null;
    builtins.appendContext path { ${path} = { path = true; }; };
  kernelConfig = artifacts.config // rec {
    isSet = name: builtins.hasAttr ("CONFIG_" + name) artifacts.config;
    getValue = name: artifacts.config.${"CONFIG_" + name} or null;
    isYes = name: getValue name == "y";
    isNo = name: getValue name == "n";
    isModule = name: getValue name == "m";
    isEnabled = name: isYes name || isModule name;
    isDisabled = name: !isSet name || isNo name;
  };
  kernel = lib.makeOverridable ({ kernelPatches ? [ ], ... }:
    assert lib.assertMsg (kernelPatches == [ ]) "Cannot patch the installed FP6 kernel during a software update.";
    {
      type = "derivation";
      name = "linux-${artifacts.version}";
      outPath = storeOutput artifacts.kernel;
      modules = { type = "derivation"; outPath = storeOutput artifacts.modules; };
      inherit (artifacts) version modDirVersion features;
      inherit (pkgs) stdenv;
      config = kernelConfig;
      configfile = pkgs.writeText "installed-fp6-kernel-config" artifacts.configText;
      kernelOlder = lib.versionOlder artifacts.version;
      kernelAtLeast = lib.versionAtLeast artifacts.version;
      isZen = false;
      isLTS = false;
      dev = throw "Kernel headers require an explicit FP6 development build.";
    }) { };
in {
  inherit kernel;
  firmware = storeOutput artifacts.firmware;
  extraModules = map storeOutput (artifacts.extraModules or [ ]);
}
