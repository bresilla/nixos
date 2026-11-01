{
  config,
  firmwares,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  rootLabel = "nixos-tb321fu";
  rootfs = pkgs.callPackage (modulesPath + "/../lib/make-ext4-fs.nix") {
    storePaths = [ config.system.build.toplevel ];
    volumeLabel = rootLabel;
    populateImageCommands = "mkdir -p ./files/boot";
  };
in
{
  # As Armada lays it out: the loader in boot_a, GRUB's FAT at the start of super, the
  # root in userdata. Android's system lives in super, so it is gone until stock
  # firmware is restored.
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/${rootLabel}";
      fsType = "ext4";
      autoResize = true;
    };
    # A 512-byte FAT on a 4096-byte disk, so it needs a loop device.
    "/boot" = {
      device = "/dev/disk/by-partlabel/super";
      fsType = "vfat";
      options = [
        "loop"
        "umask=0077"
        "nofail"
      ];
    };
  };

  # Android's firmware partitions share the internal UFS; udisks must never mount or
  # offer them, nor fwupd update UFS firmware.
  services.udev.extraRules = ''
    SUBSYSTEM=="block", ENV{ID_PATH}=="platform-1d84000.ufs-*", ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0"
  '';
  services.fwupd.enable = lib.mkForce false;

  boot.postBootCommands = ''
    if [ -f /nix-path-registration ]; then
      ${config.nix.package}/bin/nix-store --load-db < /nix-path-registration
      touch /etc/NIXOS
      ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
      rm /nix-path-registration
    fi
  '';

  # What the install flashes: boot.img, super.img and userdata.img.zst.
  system.build.tb321fuImages =
    pkgs.runCommand "tb321fu-images"
      {
        nativeBuildInputs = with pkgs.buildPackages; [
          bash
          dosfstools
          mtools
          zstd
        ];
      }
      ''
        mkdir -p $out work/boot/grub
        cp ${firmwares.tb321fu-loader}/boot.img $out/boot.img

        cp -r --no-preserve=mode ${firmwares.tb321fu-loader}/EFI work/EFI
        cp -r --no-preserve=mode ${firmwares.tb321fu-loader}/boot/grub/. work/boot/grub/
        echo 'configfile /boot/grub/grub.cfg' > work/EFI/BOOT/grub.cfg
        bash ${config.system.build.tb321fuBootFiles} ${config.system.build.toplevel} "$PWD/work"

        truncate -s 512M super.img
        mkfs.vfat -F 32 -n Y700BOOT super.img
        mcopy -s -i super.img work/EFI work/boot work/current ::/
        mv super.img $out/super.img

        zstd -T0 --no-progress ${rootfs} -o $out/userdata.img.zst
      '';
}
