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
  toplevel = config.system.build.toplevel;
  rootfs = pkgs.callPackage (modulesPath + "/../lib/make-ext4-fs.nix") {
    storePaths = [ config.system.build.toplevel ];
    volumeLabel = rootLabel;
    populateImageCommands = "mkdir -p ./files/boot";
  };
in
{
  # As Armada lays it out: the loader in boot_a, the EFI FAT at the start of super, the
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
        mkdir -p $out work/EFI/BOOT work/EFI/systemd work/EFI/nixos work/loader/entries
        cp ${firmwares.tb321fu-loader}/boot.img $out/boot.img
        cp ${firmwares.tb321fu-loader}/EFI/BOOT/QCOMRAMP.EFI work/EFI/BOOT/

        # systemd-boot and a first entry per panel; the first switch on the tablet
        # replaces the entries with NixOS's own.
        sdboot=${config.systemd.package}/lib/systemd/boot/efi/systemd-bootaa64.efi
        cp $sdboot work/EFI/BOOT/BOOTAA64.EFI
        cp $sdboot work/EFI/systemd/systemd-bootaa64.efi
        cp ${toplevel}/kernel work/EFI/nixos/Image
        cp ${toplevel}/initrd work/EFI/nixos/initrd
        for dtb in sm8650-lenovo-tb321fu sm8650-lenovo-tb321fu-csot; do
          cp ${toplevel}/dtbs/qcom/$dtb.dtb work/EFI/nixos/$dtb.dtb
        done
        entry() {
          printf 'title %s\nlinux /EFI/nixos/Image\ninitrd /EFI/nixos/initrd\ndevicetree /EFI/nixos/%s.dtb\noptions init=%s/init %s\n' \
            "$2" "$3" ${toplevel} "$(< ${toplevel}/kernel-params)" > work/loader/entries/$1.conf
        }
        entry nixos-generation-1 NixOS sm8650-lenovo-tb321fu
        entry nixos-generation-1-specialisation-csot "NixOS (csot)" sm8650-lenovo-tb321fu-csot
        echo 'default nixos-generation-1.conf' > work/loader/loader.conf

        truncate -s 512M super.img
        mkfs.vfat -F 32 -n Y700BOOT super.img
        mcopy -s -i super.img work/EFI work/loader ::/
        mv super.img $out/super.img

        zstd -T0 --no-progress ${rootfs} -o $out/userdata.img.zst
      '';
}
