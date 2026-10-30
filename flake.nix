{
  description = "Personal NixOS configurations";

  # nixConfig must be a literal; keep it in sync with shared/caches.json.
  nixConfig = {
    extra-substituters = [
      "https://cache.bresilla.com/bresilla"
      "https://cache.numtide.com"
      "https://nix-community.cachix.org"
      "https://ros.cachix.org"
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "bresilla:zsecaZYIrjCJQS4AuGPmEVU5PRkiMmB/Mds3KaCzTvE="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Keep each upstream lock so these packages match the Cachix builds.
    oslo.url = "github:termworks/oslo";
    hexe.url = "github:termworks/hexe";
    drop.url = "github:termworks/drop";
    pixy.url = "github:termworks/pixy";
    lule.url = "github:termworks/lule";
    geto.url = "github:termworks/geto";
    trek.url = "github:termworks/trek";
    wing.url = "github:termworks/wing";
    goku.url = "github:termworks/goku";
    # The engine eva runs on, a release tag; eva itself lives in configs/assets/eva.
    morf.url = "github:paneworks/morf/v0.6.1";
    # Keeps its own nixpkgs-unstable so builds match cache.numtide.com.
    llm-agents.url = "github:numtide/llm-agents.nix";
    # NixOS support for the DGX Spark (GB10): its module, kernel source and config.
    dgx-spark = {
      url = "github:graham33/nixos-dgx-spark/9c8131eeec3535a28aed136db7da464280d232ac";
      flake = false;
    };
    # Board support: the Surface Pro's linux-surface kernel, touch and thermal setup.
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    # Raspberry Pi kernel, firmware and boot setup; its own nixpkgs keeps its Cachix hits.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi";
    # NVIDIA Jetson support (JetPack 5–7): kernel, firmware, CUDA and the flash scripts.
    jetpack-nixos.url = "github:anduril/jetpack-nixos";
    jetpack-nixos.inputs.nixpkgs.follows = "nixpkgs";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ nixpkgs, disko, home-manager, oslo, hexe, drop, pixy, lule, geto, trek, wing, goku, morf, ... }:
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
          termworks = { inherit oslo hexe drop pixy lule geto trek wing goku; };
          paneworks = { inherit morf; };
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
      mkHost = role: device: pcBootTools: nixpkgs.lib.nixosSystem {
        # Needed in imports, so a special argument rather than a module one.
        specialArgs = {
          dgxSpark = inputs.dgx-spark;
          nixosHardware = inputs.nixos-hardware;
          nixos-raspberrypi = inputs.nixos-raspberrypi;
          jetpack-nixos = inputs.jetpack-nixos;
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
      };
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
