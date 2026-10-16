{
  imports = [
    ./hardware.nix
    ./disko.nix
    ./modem.nix
  ];
  # Remote Hyprland session over RDP, started at boot.
  bresilla.system.remote.rdp = {
    enable = true;
    autoStart = true;
  };
}
