# OS on the NVMe; container state on two SATA SSDs mirrored.
#
#   850 EVO ══ 860 EVO          ← mdadm: exact copies
#           │
#      md0 (465 GB)
#           │
#      LVM "data"
#           │
#         btrfs
#           │
#      containers               ← /var/lib/nixos-containers
let
  btrfsOpts = [ "noatime" "compress=zstd:3" "ssd" ];
  member = id: {
    type = "disk"; device = "/dev/disk/by-id/ata-Samsung_SSD_${id}";
    content = { type = "gpt"; partitions = {
      md = { size = "100%"; content = { type = "mdraid"; name = "md0"; }; };
    }; };
  };
in {
  disko.devices = {
    disk."disk1" = { type = "disk"; device = "/dev/nvme0n1";
      content = { type = "gpt"; partitions = {
        ESP = { priority = 1; size = "1024M"; type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; }; };
        pv = { size = "487354M"; content = { type = "lvm_pv"; vg = "pool"; }; };
      }; }; };
    lvm_vg."pool" = { type = "lvm_vg"; lvs = {
      "root" = { size = "97468M"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@root" = { mountpoint = "/"; mountOptions = btrfsOpts; }; }; }; };
      "home" = { size = "48732M"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@home" = { mountpoint = "/home"; mountOptions = btrfsOpts; }; }; }; };
      "nix" = { size = "341140M"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@nix" = { mountpoint = "/nix"; mountOptions = btrfsOpts; }; }; }; };
    }; };

    disk."sata-a1" = member "850_EVO_500GB_S21JNXAG518833V";
    disk."sata-a2" = member "860_EVO_500GB_S3Z2NB0M326073X";
    mdadm."md0" = { type = "mdadm"; level = 1; content = { type = "lvm_pv"; vg = "data"; }; };

    lvm_vg."data" = { type = "lvm_vg"; lvs = {
      "store" = { size = "100%FREE"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = {
        "/@containers" = { mountpoint = "/var/lib/nixos-containers"; mountOptions = btrfsOpts ++ [ "nofail" ]; };
      }; }; };
    }; };
  };
}
