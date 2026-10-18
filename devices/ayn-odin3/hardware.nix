{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.bresilla.odin3;
  odin3 = import ./kernel { buildSystem = cfg.kernelBuildSystem; };
in
{
  options.bresilla.odin3.kernelBuildSystem = lib.mkOption {
    type = lib.types.enum [
      "aarch64-linux"
      "x86_64-linux"
    ];
    default = "x86_64-linux";
    description = "Where the kernel compiles. It cross-compiles on x86_64 so the device reuses the
      same store path on updates instead of compiling its own.";
  };

  config = {
    boot.kernelPackages = pkgs.linuxPackagesFor odin3.kernel;
    hardware.firmware = [ (lib.hiPrio odin3.firmware) ];
    hardware.deviceTree.enable = true;

    boot.initrd = {
      includeDefaultModules = false;
      # USB-C runs host mode only once the ADSP answers pmic-glink, so the root
      # drive needs the ADSP and its firmware before the root mounts.
      # Armada's initrd carries every module; devices waiting on a supplier
      # module that lives on the USB root would never appear. kernel/initrd-modules
      # lists the platform's modules, generated from the kernel build.
      availableKernelModules = lib.filter (name: name != "") (
        lib.splitString "\n" (builtins.readFile ./kernel/initrd-modules)
      );
      extraFirmwarePaths = [
        "qcom/sm8750/ayn/odin3/adsp.mbn"
        "qcom/sm8750/ayn/odin3/adsp_dtb.mbn"
      ];
    };

    # Armada's arguments; the panel is mounted rotated. Strict device links
    # also order suspend and resume, which hangs on wake without them.
    boot.kernelParams = [
      "console=tty0"
      "fbcon=rotate:1"
      "fw_devlink.strict=1"
      "pcie_ports=compat"
      "swiotlb=8192"
      # Deep sleep never resumes on this SoC; Armada suspends to s2idle too.
      "mem_sleep_default=s2idle"
    ];
    boot.consoleLogLevel = 7;
  };
}
