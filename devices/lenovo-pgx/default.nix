{ lib, pkgs, dgxSpark, ... }:
let
  # Always cross-compiled on x86_64, so lama reuses the kernel built on tron.
  spark = import ./kernel {
    inherit dgxSpark;
    buildSystem = "x86_64-linux";
  };
  # NVIDIA's libraries and tools from the system's own packages, at the module's version.
  driver = pkgs.linuxPackages.nvidiaPackages.latest.override { libsOnly = true; };
  # The GSP firmware the open module loads, from the same installer; libsOnly leaves it out.
  gspFirmware = pkgs.runCommand "nvidia-gsp-firmware-${driver.version}" { nativeBuildInputs = [ pkgs.libarchive ]; } ''
    # Unpacked as nixpkgs does: the installer's own extractor needs a host loader.
    skip=$(sed 's/^skip=//; t; d' ${driver.src})
    tail -n +"$skip" ${driver.src} | bsdtar xf -
    install -Dm644 -t "$out/lib/firmware/nvidia/${driver.version}" firmware/*.bin
  '';
  # nvidia-smi and the other tools libsOnly leaves out, linked to the driver's libraries.
  nvidiaTools = pkgs.runCommand "nvidia-tools-${driver.version}" { nativeBuildInputs = [ pkgs.libarchive pkgs.patchelf ]; } ''
    skip=$(sed 's/^skip=//; t; d' ${driver.src})
    tail -n +"$skip" ${driver.src} | bsdtar xf -
    install -Dm755 -t "$out/bin" nvidia-smi nvidia-debugdump nvidia-cuda-mps-control nvidia-cuda-mps-server nvidia-bug-report.sh
    for tool in nvidia-smi nvidia-debugdump nvidia-cuda-mps-control nvidia-cuda-mps-server; do
      patchelf --set-interpreter "$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)" \
        --set-rpath ${lib.makeLibraryPath [ driver pkgs.stdenv.cc.cc ]} "$out/bin/$tool"
    done
  '';
in
{
  imports = [
    ./hardware.nix
    ./disko.nix
    ../shared/uefi.nix
    "${dgxSpark}/modules/dgx-spark.nix"
  ];
  networking.hostName = "lama";
  bresilla.nix.buildOnTron = true;
  # The workstation profile's x86-only parts.
  bresilla.programs.isaacsim.enable = false;
  boot.binfmt.emulatedSystems = lib.mkForce [ ];

  hardware.dgx-spark.enable = true;
  boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor spark.kernel);
  hardware.nvidia.package = lib.mkForce (
    driver
    // {
      bin = nvidiaTools;
      open = spark.nvidiaOpen;
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
      message = "lama: nixpkgs.config.cudaSupport must stay off system-wide.";
    }
    {
      assertion = lib.hasPrefix driver.version spark.nvidiaOpen.version;
      message = "lama: the NVIDIA libraries and kernel module versions differ.";
    }
  ];
}
