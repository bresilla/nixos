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
  disko.devices = {
    # The 970 EVO Plus that held the old Ubuntu 24.04; the other disks join later.
    disk.disk1 = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNM0TA05033V";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            size = "1024M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
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
          size = "131072M";
          content = btrfs { "/@root" = "/"; };
        };
        home = {
          size = "131072M";
          content = btrfs { "/@home" = "/home"; };
        };
        nix = {
          size = "262144M";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/nix";
            mountOptions = [ "noatime" ];
          };
        };
        pkg = {
          size = "131072M";
          content = btrfs { "/@pkg" = "/pkg"; };
        };
        swap = {
          size = "65536M";
          content.type = "swap";
        };
        # The old Ubuntu's ~/data, at the same place.
        data = {
          size = "204800M";
          content = btrfs { "/@data" = "/home/bresilla/data"; };
        };
      };
    };
  };
}
