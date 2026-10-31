# The 128 GB NVMe: EFI + LVM + btrfs, as on the other machines, sized for a small disk.
{
  disko.devices = {
    disk."disk1" = { type = "disk"; device = "/dev/disk/by-id/nvme-SAMSUNG_KUS020203M-B000_S38WNY1J562371";
      content = { type = "gpt"; partitions = {
        ESP = { priority = 1; size = "1024M"; type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; }; };
        pv = { size = "100%"; content = { type = "lvm_pv"; vg = "pool"; }; };
      }; }; };
    lvm_vg."pool" = { type = "lvm_vg"; lvs = {
      "swap" = { size = "8G"; content.type = "swap"; };
      "root" = { size = "30G"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@root" = { mountpoint = "/"; mountOptions = [ "noatime" "compress=zstd:3" "ssd" ]; }; }; }; };
      "nix" = { size = "60G"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@nix" = { mountpoint = "/nix"; mountOptions = [ "noatime" "compress=zstd:3" "ssd" ]; }; }; }; };
      "home" = { size = "100%FREE"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@home" = { mountpoint = "/home"; mountOptions = [ "noatime" "compress=zstd:3" "ssd" ]; }; }; }; };
    }; };
  };
}
