{ lib, pkgs, ... }:

{
  # Everything a laptop has; it stays plugged in, boots headless and serves its desktop over RDP.
  imports = [ ../laptop ];

  bresilla.features.system.laptopPower.enable = false;
  bresilla.features.system.tlp.enable = false;

  bresilla.programs.isaacsim.enable = lib.mkDefault true;
  # Builds images for the ARM devices (phone, Odin 3) under emulation.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Boots to a console; the desktop runs only as the remote session, started over SSH
  # with `sudo hypr-remote start`.
  services.greetd.enable = lib.mkForce false;
  # Morf still adds wants to greetd.service; masking it keeps that stub from starting.
  systemd.services.greetd.enable = false;
  systemd.defaultUnit = lib.mkForce "multi-user.target";
  # Morf still gives the greeter a home; without greetd it needs to be a system user.
  users.users.greeter = {
    isSystemUser = true;
    group = "greeter";
  };
  users.groups.greeter = { };
  # A local Ollama on the GPU, through Vulkan: cached for x86 and ARM, unlike the CUDA build.
  # It listens everywhere, but only the trusted NetBird interface lets other machines in.
  services.ollama = {
    enable = true;
    package = pkgs.ollama-vulkan;
    host = "0.0.0.0";
  };
  environment.sessionVariables.OLLAMA_HOST = "127.0.0.1:11434";

  bresilla.system.remote.rdp = {
    enable = lib.mkDefault true;
    autoStart = lib.mkDefault false;
  };
}
