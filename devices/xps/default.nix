{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];
  # Run libvirt/virsh on this machine.
  bresilla.features.system.virtualisation.enable = true;
}
