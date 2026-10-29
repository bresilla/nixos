# OS on the eMMC; data on four NVMe drives mirrored in pairs.
#
#   980 PRO ══ 980 PRO       990 PRO ══ 990 EVO     ← mdadm: exact copies
#         │                        │
#    md0 (2 TB)               md1 (2 TB)
#         └───────────┬────────────┘
#                     │
#              LVM "data" (4 TB)                    ← joins both pairs
#                     │
#                   btrfs
#                     │
#            ┌────────┼────────┐
#         media    photos    docs                   ← subvolumes = shares
let
  btrfsOpts = [ "noatime" "compress=zstd:3" "ssd" ];
  dataOpts = btrfsOpts ++ [ "nofail" ];
  member = id: md: {
    type = "disk"; device = "/dev/disk/by-id/nvme-Samsung_SSD_${id}";
    content = { type = "gpt"; partitions = {
      md = { size = "100%"; content = { type = "mdraid"; name = md; }; };
    }; };
  };
in {
  disko.devices = {
    disk."disk1" = { type = "disk"; device = "/dev/mmcblk0";
      content = { type = "gpt"; partitions = {
        ESP = { priority = 1; size = "1024M"; type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; }; };
        pv = { size = "58608M"; content = { type = "lvm_pv"; vg = "pool"; }; };
      }; }; };
    lvm_vg."pool" = { type = "lvm_vg"; lvs = {
      "root" = { size = "5860M"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@root" = { mountpoint = "/"; mountOptions = btrfsOpts; }; }; }; };
      "home" = { size = "5860M"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@home" = { mountpoint = "/home"; mountOptions = btrfsOpts; }; }; }; };
      "nix" = { size = "46880M"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@nix" = { mountpoint = "/nix"; mountOptions = btrfsOpts; }; }; }; };
    }; };

    # Mirror pairs: same model together, so each pair wears evenly.
    disk."nvme-a1" = member "980_PRO_2TB_S69ENX0T906351L" "md0";
    disk."nvme-a2" = member "980_PRO_2TB_S69ENX0T906359P" "md0";
    disk."nvme-b1" = member "990_PRO_2TB_S7DNNJ0X238974R" "md1";
    disk."nvme-b2" = member "990_EVO_2TB_S7GDNS0WC06262B" "md1";
    mdadm."md0" = { type = "mdadm"; level = 1; content = { type = "lvm_pv"; vg = "data"; }; };
    mdadm."md1" = { type = "mdadm"; level = 1; content = { type = "lvm_pv"; vg = "data"; }; };

    lvm_vg."data" = { type = "lvm_vg"; lvs = {
      "store" = { size = "100%FREE"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = {
        "/@media" = { mountpoint = "/data/media"; mountOptions = dataOpts; };
        "/@photos" = { mountpoint = "/data/photos"; mountOptions = dataOpts; };
        "/@docs" = { mountpoint = "/data/docs"; mountOptions = dataOpts; };
      }; }; };
    }; };
  };
}
