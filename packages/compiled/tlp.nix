{ tlp }:

# NixOS builds tlp with NetworkManager support, so cache.nixos.org never has it.
tlp.override { enableRDW = true; }
