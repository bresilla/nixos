config:
let kernel = config.boot.kernelPackages.kernel;
in {
  kernel = kernel.outPath;
  modules = (kernel.modules or kernel).outPath;
  extraModules = map toString (config.boot.extraModulePackages or [ ]);
  firmware = config.hardware.firmware.outPath;
  inherit (kernel) version modDirVersion features;
  config = builtins.removeAttrs kernel.config [
    "isSet" "getValue" "isYes" "isNo" "isModule" "isEnabled" "isDisabled"
  ];
}
