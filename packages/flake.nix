{
  description = "Packages not in nixpkgs, or built differently, served from cache.bresilla.com";

  # compiled/: built from source, or a patched nixpkgs package.
  # extracted/: a vendor's binary, only unpacked and patched.
  # Modules use these as `bresilla.<name>`; a missing pin stops the update.

  # Its own lock, so CI and every machine agree on the exact store paths.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  # RDP server for Hyprland: the bresilla fork, which adds SSH-key login (--auth-mode ssh)
  # and NVIDIA NVENC encoding (--h264-backend nvenc).
  inputs.hypr-rdp = {
    url = "github:bresilla/hypr-rdp/6a28d51b6dcd2be38e10b0785e9c08ee338d6548";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Face authentication: only the core package (daemon, CLI, PAM modules), no GUI.
  # It keeps its own nixpkgs: it needs a newer Rust than nixos-26.05 ships.
  inputs.gaze.url = "github:GunduLabs/gaze/v0.3.10";


  outputs =
    { nixpkgs, hypr-rdp, gaze, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          freerdp = pkgs.callPackage ./compiled/freerdp.nix { };
          inputplumber = pkgs.callPackage ./compiled/inputplumber.nix { };
          usb-signaller = pkgs.callPackage ./compiled/usb-signaller.nix { };
          steamos-manager = pkgs.callPackage ./compiled/steamos-manager.nix { };
          modemmanager = pkgs.callPackage ./compiled/modemmanager.nix { };
          tlp = pkgs.callPackage ./compiled/tlp.nix { };
          gaze = gaze.packages.${system}.gaze;
          hypr-rdp = hypr-rdp.packages.${system}.hypr-rdp;
          breezex-cursor = pkgs.callPackage ./extracted/breezex-cursor.nix { };
          privaxy = pkgs.callPackage ./extracted/privaxy.nix { };
        }
        # WiFiman Teleport: Ubiquiti ships the daemon for x86_64 only.
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          wifiman-desktopd = pkgs.callPackage ./extracted/wifiman-desktopd.nix { };
          wifiman = pkgs.callPackage ./compiled/wifiman.nix { };
        }
        # The Fairphone 6's own drivers, and Windows games on ARM64 Steam.
        // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
          proton-cachyos-arm64 = pkgs.callPackage ./extracted/proton-cachyos-arm64.nix { };
          imsd = pkgs.callPackage ./compiled/imsd.nix { };
          fingerprintd = pkgs.callPackage ./compiled/fingerprintd.nix { };
          hexagonrpc = pkgs.callPackage ./compiled/hexagonrpc.nix { };
          callaudiod = pkgs.callPackage ./compiled/callaudiod.nix { };
          iio-sensor-proxy = pkgs.callPackage ./compiled/iio-sensor-proxy { };
        }
      );
    };
}
