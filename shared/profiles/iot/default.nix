{ lib, pkgs, ... }:

{
  # A workstation without its heavy parts: the desktop stays (over RDP), Ollama, Isaac Sim,
  # emulation, the Flatpak apps and spotifyd go.
  imports = [ ../workstation ];

  services.ollama.enable = lib.mkForce false;
  environment.sessionVariables.OLLAMA_HOST = lib.mkForce "lama.netbird:11434";
  bresilla.programs.isaacsim.enable = lib.mkForce false;
  boot.binfmt.emulatedSystems = lib.mkForce [ ];
  bresilla.programs.flatpak.apps = lib.mkForce [ ];
  bresilla.services.spotifyd.enable = lib.mkForce false;
  bresilla.services.netbird.routingFeatures = lib.mkDefault "client";

  # CAN bus work: SocketCAN tools (candump, cansend, …) and cantools for DBC decoding.
  environment.systemPackages = [
    pkgs.can-utils
    pkgs.python3Packages.cantools
  ];
}
