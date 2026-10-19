{ lib, pkgs, dgxSpark, ... }:
let
  # Always cross-compiled on x86_64, so edge reuses the kernel built on tron.
  edge = import ./kernel {
    inherit dgxSpark;
    buildSystem = "x86_64-linux";
  };
  # NVIDIA's libraries and tools from the system's own packages, at the module's version.
  driver = pkgs.linuxPackages.nvidiaPackages.latest.override { libsOnly = true; };
  # The GSP firmware the open module loads, from the same installer; libsOnly leaves it out.
  gspFirmware = pkgs.runCommand "nvidia-gsp-firmware-${driver.version}" { } ''
    sh ${driver.src} -x --target nvidia > /dev/null
    install -Dm644 -t "$out/lib/firmware/nvidia/${driver.version}" nvidia/firmware/*.bin
  '';
in
{
  imports = [
    ./hardware.nix
    ./disko.nix
    ../shared/uefi.nix
    "${dgxSpark}/modules/dgx-spark.nix"
  ];
  networking.hostName = "edge";

  hardware.dgx-spark.enable = true;
  boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor edge.kernel);
  hardware.nvidia.package = lib.mkForce (
    driver
    // {
      bin = driver;
      open = edge.nvidiaOpen;
      firmware = gspFirmware;
    }
  );

  # CUDA lives in development shells; system-wide it would rebuild every CUDA-capable
  # package, none of which the binary caches carry.
  nixpkgs.config.cudaSupport = false;
  # No containers on this machine.
  virtualisation.podman.enable = lib.mkForce false;
  hardware.nvidia-container-toolkit.enable = lib.mkForce false;
  # nvtop needs only the NVML header from CUDA, not the multi-GB toolkit.
  nixpkgs.overlays = [
    (final: prev: {
      nvtopPackages = prev.nvtopPackages // {
        nvidia = prev.nvtopPackages.nvidia.override { cudatoolkit = prev.cudaPackages.cuda_nvml_dev; };
      };
    })
  ];
  # Headless: no GTK settings app.
  hardware.nvidia.nvidiaSettings = lib.mkForce false;

  assertions = [
    {
      # nixpkgs.config merges without priorities; fail rather than rebuild everything.
      assertion = !pkgs.config.cudaSupport;
      message = "edge: nixpkgs.config.cudaSupport must stay off system-wide.";
    }
    {
      assertion = lib.hasPrefix driver.version edge.nvidiaOpen.version;
      message = "edge: the NVIDIA libraries and kernel module versions differ.";
    }
  ];
}
