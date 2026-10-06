{ lib, ... }:

{
  # Board-specific kernels, firmware and bootloaders belong to hardware.nix.
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  bresilla.features.desktop.enable = lib.mkDefault false;
  bresilla.features.network.wifi.enable = lib.mkDefault true;
  bresilla.features.system.ssh.enable = lib.mkDefault true;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "client";
  services.smartd.enable = false;
}
