{ lib, ... }:
let
  # machine.nix picks the storage (`storage = "nvme";`); imports cannot depend on config,
  # so it is read here. Without it the Pi boots from its SD card, as rasp-image builds.
  machine = if builtins.pathExists ../../machine.nix then import ../../machine.nix else { };
  nvme = (machine.storage or "sd") == "nvme";
  nixos-raspberrypi = import ./nixos-raspberrypi.nix;
in
{
  # Vendor kernel and firmware from nixos-raspberrypi, prebuilt on its Cachix.
  imports = with nixos-raspberrypi.nixosModules; [
    nixpkgs-rpi
    nixos-raspberrypi.lib.inject-overlays
    trusted-nix-caches
    raspberry-pi-5.base
    raspberry-pi-5.display-vc4
    raspberry-pi-5.bluetooth
  ] ++ (if nvme then [ ./nvme.nix ] else [ sd-image ]);
  # Its modules expect themselves as an argument.
  _module.args.nixos-raspberrypi = nixos-raspberrypi;
  networking.hostName = "rasp";
  # The SD-image base profile adds ZFS, which would mean compiling it for this kernel.
  boot.supportedFilesystems.zfs = lib.mkForce false;
  # An SD card has no SMART data, so smartd only fails.
  services.smartd.enable = lib.mkIf (!nvme) (lib.mkForce false);
}
