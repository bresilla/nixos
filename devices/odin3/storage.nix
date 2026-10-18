{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  cfg = config.bresilla.odin3;
  usb = cfg.storage == "usb";
  # The internal partitions get their own labels, so a USB drive with this
  # system on it can stay plugged in without mixing them up.
  labels =
    if usb then
      {
        root = "nixos-odin3";
        boot = "ODIN3-BOOT";
      }
    else
      {
        root = "odin3-root";
        boot = "ODIN3-INT";
      };
  bootMiB = 512;
  rootfs = pkgs.callPackage (modulesPath + "/../lib/make-ext4-fs.nix") {
    storePaths = [ config.system.build.toplevel ];
    volumeLabel = "nixos-odin3";
    populateImageCommands = "mkdir -p ./files/boot";
  };
in
{
  options.bresilla.odin3.storage = lib.mkOption {
    type = lib.types.enum [
      "usb"
      "internal"
    ];
    default = "usb";
    description = "Where NixOS runs: a USB drive, or the internal UFS in place of Armada.";
  };

  config = {
    fileSystems = {
      "/" = {
        device = "/dev/disk/by-label/${labels.root}";
        fsType = "ext4";
        autoResize = usb;
      };
      "/boot" = {
        device = "/dev/disk/by-label/${labels.boot}";
        fsType = "vfat";
        options = [ "umask=0077" ];
      };
    };
    boot.growPartition = usb;

    # Android and its firmware partitions share the internal UFS; udisks must
    # never mount or offer them, nor fwupd update UFS firmware.
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

    # A USB drive image laid out like Armada's: MBR, a bootable FAT partition
    # holding /KERNEL, then the root filesystem, which grows on first boot.
    system.build.odin3Image =
      pkgs.runCommand "odin3-usb.img.zst"
        {
          nativeBuildInputs = with pkgs.buildPackages; [
            dosfstools
            mtools
            util-linux
            zstd
          ];
        }
        ''
          gap=8
          rootBytes=$(stat -c %s ${rootfs})
          truncate -s $(( (gap + ${toString bootMiB}) * 1024 * 1024 + rootBytes )) image.img
          sfdisk --no-reread --no-tell-kernel image.img <<EOF
          label: dos
          start=''${gap}M, size=${toString bootMiB}M, type=c, bootable
          start=$((gap + ${toString bootMiB}))M, type=83
          EOF

          truncate -s ${toString bootMiB}M boot.img
          mkfs.vfat -F 32 -n ODIN3-BOOT boot.img
          ${lib.getExe config.system.build.odin3KernelImage} ${config.system.build.toplevel} KERNEL
          mcopy -i boot.img KERNEL ::/KERNEL

          eval "$(partx image.img -o START --nr 1 --pairs)"
          dd conv=notrunc status=none if=boot.img of=image.img seek="$START"
          eval "$(partx image.img -o START --nr 2 --pairs)"
          dd conv=notrunc status=none if=${rootfs} of=image.img seek="$START"
          zstd -T0 --no-progress image.img -o $out
        '';
  };
}
