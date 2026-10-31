{ lib, ... }:
let
  # machine.nix picks the storage (`storage = "nvme";`); imports cannot depend on config,
  # so it is read here. Without it the Pi boots from its SD card, as rasp-image builds.
  machine = if builtins.pathExists ../../machine.nix then import ../../machine.nix else { };
  nvme = (machine.storage or "sd") == "nvme";
  nixos-raspberrypi = import ../../device-recipes/raspberrypi-pi5/software/nixos-raspberrypi.nix;
in
{
  imports = [ ../../device-recipes/raspberrypi-pi5/software/hardware.nix ]
    ++ (if nvme then [ ./storage.nix ] else [ nixos-raspberrypi.nixosModules.sd-image ]);
  networking.hostName = "rasp";
  # An SD card has no SMART data, so smartd only fails.
  services.smartd.enable = lib.mkIf (!nvme) (lib.mkForce false);
}
