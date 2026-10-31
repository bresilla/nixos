let
  btrfs = mounts: {
    type = "btrfs";
    extraArgs = [ "-f" ];
    subvolumes = builtins.mapAttrs (_: mountpoint: {
      inherit mountpoint;
      mountOptions = [
        "noatime"
        "compress=zstd:3"
        "ssd"
      ];
    }) mounts;
  };
in
{
  # Generational boot entries under nixos/ on the firmware partition; the EEPROM needs
  # NVMe first in BOOT_ORDER (0xf416) to boot it with an SD card in.
  boot.loader.raspberry-pi.bootloader = "kernel";
  boot.initrd.availableKernelModules = [ "dm_mod" "dm_snapshot" "btrfs" ];

  # The 256 GB Intel 760p NVMe; the Pi's EEPROM reads config.txt and the kernels from the
  # FAT firmware partition, everything else lives in LVM.
  disko.devices = {
    disk.disk1 = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-eui.5cd2e42b81a2ec94";
      content = {
        type = "gpt";
        partitions = {
          firmware = {
            priority = 1;
            size = "1024M";
            type = "0700";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot/firmware";
              mountOptions = [ "noatime" ];
            };
          };
          pv = {
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "pool";
            };
          };
        };
      };
    };
    lvm_vg.pool = {
      type = "lvm_vg";
      lvs = {
        root = {
          size = "40960M";
          content = btrfs { "/@root" = "/"; };
        };
        nix = {
          size = "102400M";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/nix";
            mountOptions = [ "noatime" ];
          };
        };
        swap = {
          size = "8192M";
          content.type = "swap";
        };
        # disko creates 100%FREE volumes last, so doc takes what the others leave.
        doc = {
          size = "100%FREE";
          content = btrfs { "/@doc" = "/doc"; };
        };
      };
    };
  };
}
