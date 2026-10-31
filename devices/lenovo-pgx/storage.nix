# The 4 TB NVMe: the same EFI + LVM + btrfs layout as the other servers.
{
  disko.devices = {
    disk."disk1" = { type = "disk"; device = "/dev/nvme0n1";
      content = { type = "gpt"; partitions = {
        ESP = { priority = 1; size = "1024M"; type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; }; };
        pv = { size = "100%"; content = { type = "lvm_pv"; vg = "pool"; }; };
      }; }; };
    lvm_vg."pool" = { type = "lvm_vg"; lvs = {
      "root" = { size = "200G"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@root" = { mountpoint = "/"; mountOptions = [ "noatime" "compress=zstd:3" "ssd" ]; }; }; }; };
      "nix" = { size = "600G"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@nix" = { mountpoint = "/nix"; mountOptions = [ "noatime" "compress=zstd:3" "ssd" ]; }; }; }; };
      "home" = { size = "100%FREE"; content = { type = "btrfs"; extraArgs = [ "-f" ]; subvolumes = { "/@home" = { mountpoint = "/home"; mountOptions = [ "noatime" "compress=zstd:3" "ssd" ]; }; }; }; };
    }; };
  };
}
