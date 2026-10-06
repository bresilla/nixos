{ lib, ... }:

let
  pointerConfig = ''
    hl.config({ cursor = { invisible = true } })
  '';
in {
  imports = [ ./graphical.nix ../services/phone-screen.nix ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  # Phone-specific choices stay here; graphical software is shared with laptops.
  services.smartd.enable = false;
  bresilla.services.hyprland.extraConfig = pointerConfig;
  bresilla.services.morf.greeter.extraConfig = pointerConfig;
}
