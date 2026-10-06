{ lib, ... }:

{
  imports = [ ./graphical.nix ../services/phone-screen.nix ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  # Phone-specific choices stay here; graphical software is shared with laptops.
  services.smartd.enable = false;
}
