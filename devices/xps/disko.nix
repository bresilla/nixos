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
    disk.disk1 = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_4TB_S7DPNJ0Y916919Y";
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
          size = "32768M";
          content = btrfs { "/@root" = "/"; };
        };
        home = {
          size = "32768M";
          content = btrfs { "/@home" = "/home"; };
        };
        nix = {
          size = "163840M";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/nix";
            mountOptions = [ "noatime" ];
          };
        };
        pkg = {
          size = "32768M";
          content = btrfs { "/@pkg" = "/pkg"; };
        };
        doc = {
          size = "131072M";
          content = btrfs {
            "/@doc" = "/doc";
            "/@doc-code" = "/doc/code";
            "/@doc-data" = "/doc/data";
            "/@doc-self" = "/doc/self";
            "/@doc-work" = "/doc/work";
          };
        };
        swap = {
          size = "65536M";
          content.type = "swap";
        };
      };
    };
  };
}
