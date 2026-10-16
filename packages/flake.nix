{
  description = "Packages not in nixpkgs, or built differently, served from bresilla.cachix.org";

  # Its own lock, so CI and every machine agree on the exact store paths.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  # RDP server for Hyprland: the bresilla fork, which adds SSH-key login (--auth-mode ssh).
  inputs.hypr-rdp = {
    url = "github:bresilla/hypr-rdp/cd1664bc8645ebb27dc5d1dbc9ef2bd2eb022c5d";
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
          gaze = gaze.packages.${system}.gaze;
        }
        # Upstream builds for x86_64 only.
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          hypr-rdp = hypr-rdp.packages.${system}.hypr-rdp;
        }
      );
    };
}
