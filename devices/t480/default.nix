{
  imports = [
    ./hardware.nix
    ./disko.nix
    ./modem.nix
  ];
  # Remote Hyprland session over RDP, started at boot.
  bresilla.programs.remote.rdp = {
    enable = true;
    autoStart = true;
  };
}
