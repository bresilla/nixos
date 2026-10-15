{
  imports = [
    ./hardware.nix
    ./disko.nix
    ./modem.nix
  ];

  # Dotfiles from configs/, linked through the ~/.dot checkout.
  bresilla.configs.enable = true;
}
