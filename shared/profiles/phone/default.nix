{ lib, ... }:
{
  imports = [ ../shared.nix ./windows.nix ];
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  nix.settings.max-jobs = lib.mkDefault 1;
  nix.settings.cores = lib.mkDefault 2;
  services.smartd.enable = false;
  bresilla.programs.agents.enable = false;
  programs.eva.phone.enable = true;
  programs.eva.phone.gestureDriver = "native";
}
