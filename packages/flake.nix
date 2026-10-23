{
  description = "Packages not in nixpkgs, or built differently, served from bresilla.cachix.org";

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
          freerdp = pkgs.callPackage ./freerdp.nix { };
          inputplumber = pkgs.callPackage ./inputplumber.nix { };
          usb-signaller = pkgs.callPackage ./usb-signaller.nix { };
          steamos-manager = pkgs.callPackage ./steamos-manager.nix { };
          modemmanager = pkgs.callPackage ./modemmanager.nix { };
          gaze = gaze.packages.${system}.gaze;
          hypr-rdp = hypr-rdp.packages.${system}.hypr-rdp;
        }
      );
    };
}
