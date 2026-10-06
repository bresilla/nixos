config:
let kernel = config.boot.kernelPackages.kernel;
in {
  kernel = kernel.outPath;
  modules = (kernel.modules or kernel).outPath;
  firmware = config.hardware.firmware.outPath;
  inherit (kernel) version modDirVersion features;
  config = builtins.removeAttrs kernel.config [
    "isSet" "getValue" "isYes" "isNo" "isModule" "isEnabled" "isDisabled"
  ];
}
