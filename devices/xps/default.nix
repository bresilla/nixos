{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];
  # Keep the network identity of the Arch install this machine replaces.
  networking.hostName = "core";
  # Run libvirt/virsh on this machine.
  bresilla.features.system.virtualisation.enable = true;
}
