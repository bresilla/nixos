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
  # The whole 447 GB Innodisk 3TE6 NVMe as plain partitions: the JetPack 5 kernel has no
  # dm-snapshot, which NixOS needs in the initrd for LVM.
  disko.devices.disk.disk1 = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-eui.010000000000000024693e0000173141";
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
        root = {
          size = "65536M";
          content = btrfs { "/@root" = "/"; };
        };
        nix = {
          size = "196608M";
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
        doc = {
          size = "100%";
          content = btrfs { "/@doc" = "/doc"; };
        };
      };
    };
  };
}
