# risc: a StarFive VisionFive 2 Lite, booting from its microSD card. U-Boot lives in
# the SPI flash (vf2lite-flash-uboot writes it); the card holds /boot and the system.
#
# cache.nixos.org has nothing for riscv64, so the whole system is cross-compiled on an
# x86_64 builder and cached there: the board never compiles, as no device does.
{ config, lib, modulesPath, ... }:
{
  imports = [
    ../../device-recipes/starfive-visionfive2lite/software/hardware.nix
    "${modulesPath}/installer/sd-card/sd-image.nix"
  ];
  nixpkgs.buildPlatform = "x86_64-linux";
  networking.hostName = "risc";
  # llm-agents builds no riscv64 packages.
  bresilla.programs.agents.enable = false;
  # An SD card has no SMART data, so smartd only fails.
  services.smartd.enable = lib.mkForce false;
  # No firmware partition: U-Boot is in SPI flash, and boots extlinux from the card.
  sdImage = {
    imageBaseName = "risc";
    compressImage = false;
    populateFirmwareCommands = "";
    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
    '';
  };
}
