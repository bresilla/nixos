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
    # The 870 QVO holds /home and /doc; the NVMe keeps the system.
    disk.disk2 = {
      type = "disk";
      device = "/dev/disk/by-id/ata-Samsung_SSD_870_QVO_4TB_S5STNF0W408952F";
      content = {
        type = "gpt";
        partitions.pv = {
          size = "100%";
          content = {
            type = "lvm_pv";
            vg = "data";
          };
        };
      };
    };
    lvm_vg.data = {
      type = "lvm_vg";
      lvs.doc = {
        size = "100%FREE";
        content = btrfs {
          "/@home" = "/home";
          "/@doc" = "/doc";
          "/@doc-code" = "/doc/code";
          "/@doc-data" = "/doc/data";
          "/@doc-self" = "/doc/self";
          "/@doc-work" = "/doc/work";
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
      };
    };
  };
}
