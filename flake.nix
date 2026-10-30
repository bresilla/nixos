{
  description = "Personal NixOS configurations";

  # nixConfig must be a literal; keep it in sync with shared/caches.json.
  nixConfig = {
    extra-substituters = [
      "https://cache.bresilla.com/bresilla"
      "https://cache.bresilla.com/packages"
      "https://cache.bresilla.com/kernels"
      "https://cache.numtide.com"
      "https://nix-community.cachix.org"
      "https://ros.cachix.org"
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "bresilla:zsecaZYIrjCJQS4AuGPmEVU5PRkiMmB/Mds3KaCzTvE="
      "packages:xPzXK5L3tv3hfJvrfzbtQcgB//M29aqQl4uUWfn+MCw="
      "kernels:0xZuay5PzDV/ME/UMs3bIdIfF0ycwyC6i+M2YUuKbxA="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  # Termworks tools and morf are not inputs: they come only as pinned binaries from
  # cache.bresilla.com (shared/installer/cached-inputs.nix). The inputs left are
  # source; none uses GitHub's API, which allows a home 60 calls an hour:
  # nixpkgs comes from channels.nixos.org, the rest over plain git.
  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-26.05/nixexprs.tar.xz";
    nixpkgs-unstable.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    # Keeps its own nixpkgs-unstable so builds match cache.numtide.com.
    llm-agents.url = "git+https://github.com/numtide/llm-agents.nix?shallow=1";
    # Board support used by one device each (jetpack-nixos, nixos-dgx-spark,
    # nixos-raspberrypi, nixos-hardware) is fetched by that device's own folder.
    disko.url = "git+https://github.com/nix-community/disko?shallow=1";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "git+https://github.com/nix-community/home-manager?ref=release-26.05&shallow=1";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ nixpkgs, disko, home-manager, ... }:
    let
      lib = nixpkgs.lib;
      roles = [ "laptop" "workstation" "server" "phone" "handheld" "iot" ];
      deviceDirs = lib.filterAttrs (name: type:
        type == "directory" && builtins.pathExists (./devices + "/${name}/device.json")
      ) (builtins.readDir ./devices);
      devices = builtins.mapAttrs (name: _: builtins.fromJSON
        (builtins.readFile (./devices + "/${name}/device.json"))) deviceDirs;
      selected = if builtins.pathExists ./machine.nix then import ./machine.nix else null;
      legacy = selected == null && (builtins.pathExists ./disko.nix || builtins.pathExists ./hardware.nix);
      defaultDevice = role:
        if selected != null && selected.profile == role then selected.device
        else if legacy then null
        else { laptop = "lenovo-t480"; phone = "fairphone-fp6"; }.${role} or null;
      shared = { pkgs, ... }: let
        cached = import ./shared/installer/cached-inputs.nix {
          system = pkgs.stdenv.hostPlatform.system;
          manifest = if builtins.pathExists ./cache-binaries.json
            then builtins.fromJSON (builtins.readFile ./cache-binaries.json) else null;
        };
      in {
        imports = [ disko.nixosModules.disko home-manager.nixosModules.home-manager
          ./shared/default.nix ];
        _module.args = {
          inherit (cached) termworks paneworks bresilla aiNerv;
          pkgsUnstable = import inputs.nixpkgs-unstable {
            inherit (pkgs) config;
            system = pkgs.stdenv.hostPlatform.system;
          };
          llmAgents = inputs.llm-agents;
        };
      };
      profiles = lib.genAttrs roles (role: {
        imports = [ shared (./shared/profiles + "/${role}") ];
      });
      runtime = {
        # local.nix: this machine's own settings, kept in /etc/nixos and never committed.
        imports = lib.optional (builtins.pathExists ./user.nix) ./user.nix
          ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;
      };
      # A device keeps the kernel it runs: device.json's kernelNixpkgs names the nixpkgs
      # revision that built it, and the device's own config is evaluated once more with
      # that nixpkgs, only for its kernel. Change the revision to move to a new kernel.
      mkHost = role: device: pcBootTools: let
        specialArgs = { };
        kernelRev = if device != null then devices.${device}.kernelNixpkgs or null else null;
        kernelSystem = let
          src = builtins.fetchGit { url = "https://github.com/NixOS/nixpkgs"; rev = kernelRev; shallow = true; };
        in import (src + "/nixos/lib/eval-config.nix") {
          inherit specialArgs modules;
          lib = import (src + "/lib");
          system = null;
        };
        pinKernel = lib.optional (kernelRev != null) {
          boot.kernelPackages = lib.mkOverride 10 kernelSystem.config.boot.kernelPackages;
        };
        modules = [ profiles.${role} runtime ({ pkgs, ... }: {
          _module.args = {
            fp6BuildPkgs = if pcBootTools then nixpkgs.legacyPackages.x86_64-linux else pkgs;
          };
          nixpkgs.hostPlatform = lib.mkDefault (if device != null then devices.${device}.system
            else if builtins.elem role [ "phone" "handheld" "iot" ] then "aarch64-linux" else "x86_64-linux");
          networking.hostName = lib.mkDefault (if device != null then device else role);
          assertions = [ {
            assertion = device != null || legacy;
            message = "Select a saved device or supply hardware.nix/disko.nix through install.sh.";
          } ];
        }) ] ++ (if device != null then [ (./devices + "/${device}") ] else
          lib.optional (builtins.pathExists ./hardware.nix) ./hardware.nix
          ++ lib.optional (builtins.pathExists ./disko.nix) ./disko.nix
          ++ lib.optional (builtins.elem role [ "laptop" "workstation" "server" ]) ./devices/shared/uefi.nix);
      in nixpkgs.lib.nixosSystem { inherit specialArgs; modules = modules ++ pinKernel; };
      configurations = lib.genAttrs roles (role: mkHost role (defaultDevice role) false)
        // lib.mapAttrs (name: info: mkHost info.profile name false)
          (lib.filterAttrs (name: _: !(builtins.elem name roles)) devices);
      crossPhone = mkHost "phone" "fairphone-fp6" true;
      odin3Kernel = system: import ./devices/ayn-odin3/kernel { buildSystem = system; };
      # The USB image cross-compiles its kernel; the device then builds its own.
      odin3Image = system: (configurations."ayn-odin3".extendModules {
        modules = [ { bresilla.odin3 = { kernelBuildSystem = system; storage = "usb"; }; } ];
      }).config.system.build.odin3Image;
    in {
      lib.deviceCatalog = devices;
      nixosModules = { default = shared; } // profiles;
      nixosConfigurations = configurations;
      packages.aarch64-linux = {
        fp6-boot = configurations."fairphone-fp6".config.system.build.fp6BootImage;
        fp6-userdata = configurations."fairphone-fp6".config.system.build.image;
        odin3-image = odin3Image "aarch64-linux";
        rasp-image = configurations."raspberrypi-pi5".config.system.build.sdImage;
        odin3-kernel-config = (odin3Kernel "aarch64-linux").config;
      };
      packages.x86_64-linux = {
        fp6-boot = crossPhone.config.system.build.fp6BootImage;
        fp6-userdata = crossPhone.config.system.build.image;
        odin3-image = odin3Image "x86_64-linux";
        installer-iso = (nixpkgs.lib.nixosSystem {
          modules = [ ./shared/installer/iso.nix ];
        }).config.system.build.isoImage;
        odin3-kernel-config = (odin3Kernel "x86_64-linux").config;
      };
      devShells = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
        fp6 = import ./devices/fairphone-fp6/development/shell.nix { pkgs = import nixpkgs { inherit system; }; };
      });
    };
}
