{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.bresilla.odin3;
  odin3 = import ./kernel.nix { buildSystem = cfg.kernelBuildSystem; };
in
{
  options.bresilla.odin3.kernelBuildSystem = lib.mkOption {
    type = lib.types.enum [
      "aarch64-linux"
      "x86_64-linux"
    ];
    default = "aarch64-linux";
    description = "Where the kernel compiles; the USB image cross-compiles it on x86_64.";
  };

  config = {
    boot.kernelPackages = pkgs.linuxPackagesFor odin3.kernel;
    hardware.firmware = [ (lib.hiPrio odin3.firmware) ];
    hardware.deviceTree.enable = true;

    boot.initrd = {
      includeDefaultModules = false;
      # USB-C runs host mode only once the ADSP answers pmic-glink, so the root
      # drive needs the ADSP and its firmware before the root mounts.
      availableKernelModules = [ "qcom_q6v5_pas" ];
      extraFirmwarePaths = [
        "qcom/sm8750/ayn/odin3/adsp.mbn"
        "qcom/sm8750/ayn/odin3/adsp_dtb.mbn"
      ];
    };

    # Armada's arguments; the panel is mounted rotated.
    boot.kernelParams = [
      "console=tty0"
      "fbcon=rotate:1"
      "fw_devlink.strict=1"
      "pcie_ports=compat"
      "swiotlb=8192"
    ];
  };
}
