{
  imports = [
    ./hardware.nix
    ./disko.nix
    ./modem.nix
  ];

  # Trial of configs/ in place of the ~/.dot checkout.
  bresilla.configs.enable = true;
}
