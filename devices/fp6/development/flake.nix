{
  description = "Explicit FP6 kernel and firmware development builds";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    fp6-linux = { url = "github:milos-mainline/linux"; flake = false; };
    fp6-firmware = { url = "github:FairBlobs/FP6-firmware"; flake = false; };
    pil-squasher = { url = "github:linux-msm/pil-squasher"; flake = false; };
    fp6-kernel-config = {
      url = "file+https://gitlab.postmarketos.org/postmarketOS/pmaports/-/raw/main/device/testing/linux-postmarketos-qcom-milos/config-postmarketos-qcom-milos.aarch64";
      flake = false;
    };
  };
  outputs = { nixpkgs, fp6-linux, fp6-firmware, fp6-kernel-config, pil-squasher, ... }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
    in {
      packages = lib.genAttrs systems (system:
        let
          tools = nixpkgs.legacyPackages.${system};
          phone = import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; };
          buildPkgs = if system == "aarch64-linux" then phone else import nixpkgs {
            inherit system;
            crossSystem = lib.systems.examples.aarch64-multiplatform;
          };
          kernel = buildPkgs.callPackage ./kernel.nix {
            src = fp6-linux;
            pmaports = fp6-kernel-config;
            kernelPatches = [ ];
          };
          firmware = phone.buildEnv {
            name = "fp6-firmware";
            paths = [ (phone.callPackage ./firmware.nix { src = fp6-firmware; inherit pil-squasher; }) phone.linux-firmware ];
            pathsToLink = [ "/lib/firmware" ];
            ignoreCollisions = true;
          };
          artifacts = (import ./export-hardware.nix {
            boot.kernelPackages = { inherit kernel; };
            hardware = { inherit firmware; };
          }) // { configText = builtins.readFile kernel.configfile; };
        in {
          inherit kernel firmware;
          boot-hardware = tools.writeText "fp6-boot-hardware.json" (builtins.toJSON artifacts);
          default = kernel;
        });
      devShells = lib.genAttrs systems (system: {
        default = import ./shell.nix { pkgs = nixpkgs.legacyPackages.${system}; };
      });
    };
}
