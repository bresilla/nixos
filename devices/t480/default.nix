{
  imports = [
    ./hardware.nix
    ./disko.nix
    ./modem.nix
  ];
  # Trial of the on-demand remote Hyprland session.
  bresilla.programs.remoteDesktop.enable = true;
}
