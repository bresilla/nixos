# The FP6 kernel and firmware: milos-mainline Linux with the microphone patches,
# configured as the kernel that first ran on the phone (./config). Its nixpkgs is
# pinned apart from the system's, so updates never rebuild the kernel.
{
  buildSystem ? "aarch64-linux",
}:

let
  nixpkgsSrc = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/26f4107e47e3ad0ffd0db220469ba83b6f6d96e8.tar.gz";
    sha256 = "0k498brrpk3ckn1ldzyg3hzd4inrz9pzy4vbcci38kncsc13191r";
  };
  phone = import nixpkgsSrc {
    system = "aarch64-linux";
    config.allowUnfree = true;
  };
  buildPkgs =
    if buildSystem == "aarch64-linux" then
      phone
    else
      import nixpkgsSrc {
        localSystem = buildSystem;
        crossSystem = phone.lib.systems.examples.aarch64-multiplatform;
      };

  kernel = buildPkgs.callPackage ./kernel.nix {
    # The source Makefile's version, written here so evaluation never fetches it.
    version = "7.2.0";
    # Speaker support: MI2S link, amplifier startup and DSP clock sequencing.
    src = buildPkgs.fetchFromGitHub {
      owner = "milos-mainline";
      repo = "linux";
      rev = "08186c3d6b266113c14f255dddd8f35862e461e5";
      hash = "sha256-aq4sx9cO6ds/GBnr0qF8/acfWkv6cDQQwTAgEYjviRM=";
    };
    baseConfig = ./config;
    kernelPatches = [
      {
        name = "fp6-wcd9378-microphone";
        patch = buildPkgs.fetchpatch {
          url = "https://forgejo.catcrafts.net/Catcrafts/milos-linux/compare/1b485d51924504267c91c724322249c7d26ace7d...d73c696bf2667908db690ee4e1d2171172badc7d.diff";
          excludes = [ "arch/arm64/boot/dts/qcom/milos-fairphone-fp6.dts" ];
          hash = "sha256-qC0/D2B0F0iEItRQ/1/TX4FqaqvRrbfOYLVA1bfGZAg=";
        };
      }
      {
        name = "fp6-microphone-device-tree";
        patch = ./patches/fp6-microphone-dts.patch;
      }
      # Milos loses the UFS PHY state in system suspend, like SM8550, so the
      # link must power down (spm_lvl 5); Hibern8 fails to exit on resume.
      # From github.com/URunDEAD/fairphone6-nixos.
      {
        name = "ufs-qcom-milos-power-down";
        patch = ./patches/ufs-qcom-milos-power-down.patch;
      }
    ];
  };

  firmware = phone.buildEnv {
    name = "fp6-firmware";
    paths = [
      (phone.callPackage ./firmware.nix {
        src = phone.fetchFromGitHub {
          owner = "FairBlobs";
          repo = "FP6-firmware";
          rev = "e58a5be8fa0fb6bc5a5f2e29cc01c036ccf75710";
          hash = "sha256-CkPtCerCH/7+atDjsLmHRoDDyjCVP6U7u8cCw75iv/E=";
        };
        pil-squasher = phone.fetchFromGitHub {
          owner = "linux-msm";
          repo = "pil-squasher";
          rev = "3c9f8b8756ba6e4dbf9958570fd4c9aea7a70cf4";
          hash = "sha256-MEW85w3RQhY3tPaWtH7OO22VKZrjwYUWBWnF3IF4YC0=";
        };
      })
      phone.linux-firmware
    ];
    pathsToLink = [ "/lib/firmware" ];
    ignoreCollisions = true;
  };
in
{
  inherit kernel firmware;
}
