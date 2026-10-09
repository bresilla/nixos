{ lib, ... }:
{
  imports = [ ./shared/desktop.nix ./phone/windows.nix ];
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  nix.settings.max-jobs = lib.mkDefault 1;
  nix.settings.cores = lib.mkDefault 2;
  services.smartd.enable = false;
  programs.morf.phone.enable = true;
  programs.morf.phone.gestureDriver = "native";
}
