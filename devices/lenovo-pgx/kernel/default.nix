# NVIDIA's DGX Spark kernel (NV-Kernels 7.0, DGX OS's own) with the configuration from
# graham33/nixos-dgx-spark. Its nixpkgs is pinned apart from the system's, so updates
# never rebuild the kernel, and it cross-compiles on x86_64 like the Odin's.
{
  dgxSpark,
  buildSystem ? "aarch64-linux",
}:

let
  nixpkgsSrc = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/26f4107e47e3ad0ffd0db220469ba83b6f6d96e8.tar.gz";
    sha256 = "0k498brrpk3ckn1ldzyg3hzd4inrz9pzy4vbcci38kncsc13191r";
  };
  pkgs =
    if buildSystem == "aarch64-linux" then
      import nixpkgsSrc {
        system = "aarch64-linux";
        config.allowUnfree = true;
      }
    else
      import nixpkgsSrc {
        localSystem = buildSystem;
        crossSystem = "aarch64-linux";
        config.allowUnfree = true;
      };
  inherit (pkgs) lib;
  source = import "${dgxSpark}/kernel-configs/nvidia-kernel-source.nix";
  dgxConfig = import "${dgxSpark}/kernel-configs/nvidia-dgx-spark-${source.nvidiaKernelVersion}.nix" {
    inherit lib;
  };
  scrub = "${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to";
  kernel =
    (pkgs.buildLinux {
      src = source.mkNvidiaKernelSource pkgs;
      version = "${source.nvidiaKernelVersion}-nvidia";
      modDirVersion = source.nvidiaKernelVersion;
      kernelPatches = with pkgs.kernelPatches; [
        bridge_stp_helper
        request_key_helper
      ];
      extraMeta.branch = lib.versions.majorMinor source.nvidiaKernelVersion;
      ignoreConfigErrors = true;
      # The same additions as graham33's module makes to NVIDIA's configuration.
      structuredExtraConfig =
        dgxConfig
        // (with lib.kernel; {
          USB_STORAGE = yes;
          USB_UAS = yes;
          OVERLAY_FS = yes;
          UEVENT_HELPER = no;
          UBUNTU_HOST = no;
          TCG_CRB = yes;
          # CUDA's unified memory shares page tables with the GB10 through the SMMU (ATS); nixpkgs
          # 26.05 leaves this off, and graham33's config only lists changes from newer defaults.
          ARM_SMMU_V3_SVA = yes;
          # Nothing here needs Rust, and a cross build would compile its toolchain first.
          RUST = lib.mkForce no;
        });
    }).overrideAttrs
      (old: {
        # UBSAN source paths tie Image and modules to the dev output; modules stay signed.
        stripExclude = (old.stripExclude or [ ]) ++ [ "*.ko" ];
        preInstall = (old.preInstall or "") + ''
          find "$buildRoot" -name '*.ko' -print0 | xargs -0 -r ${scrub} -t "$dev"
        '';
        postFixup = (old.postFixup or "") + ''
          find "$out" -type f -print0 | xargs -0 -r ${scrub} -t "$dev"
        '';
      });
  # NVIDIA's open kernel module, built against this kernel; the libraries come from the system.
  nvidiaOpen = (import ../nvidia.nix (pkgs.linuxPackagesFor kernel).nvidiaPackages).open.overrideAttrs (old: {
    stripExclude = (old.stripExclude or [ ]) ++ [ "*.ko" ];
    preInstall = (old.preInstall or "") + ''
      find . -name '*.ko' -print0 | xargs -0 -r ${scrub} -t ${kernel.dev}
    '';
  });
in
{
  inherit kernel nvidiaOpen;
}
