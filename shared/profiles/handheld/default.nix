{ lib, pkgs, ... }:
{
  # A touch handheld with game controls: the shared desktop with Morf's touch
  # gestures, but no modem. Device modules set the panel's rotation and scale.
  imports = [ ../shared.nix ];
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  services.smartd.enable = false;
  bresilla.features.network.cellular.enable = false;
  programs.morf.phone.enable = true;
  programs.morf.phone.gestureDriver = "native";
  bresilla.programs.steamArm64.enable = lib.mkDefault true;
  bresilla.programs.steamArm64.session.enable = lib.mkDefault true;

  # InputPlumber presents the built-in controls as one standard gamepad for
  # Steam; 0.80 added the AYN Odin 3, nixpkgs has 0.78.
  services.inputplumber = {
    enable = true;
    package = pkgs.inputplumber.overrideAttrs (final: old: {
      version = "0.82.0";
      src = pkgs.fetchFromGitHub {
        owner = "ShadowBlip";
        repo = "InputPlumber";
        tag = "v${final.version}";
        hash = "sha256-JG0NdKV8A77NkJr/2CiKAElrEzjto3xyzOODyRl1dZE=";
      };
      cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
        inherit (final) src;
        hash = "sha256-WW0OTz+pqy5mmLq+Afn/NhXmHrVtDOadTLMlGDJd3bw=";
      };
    });
  };
}
