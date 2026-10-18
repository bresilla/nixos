{ ... }:
let
  # Same subvolumes as /doc/code and /doc/data, also at the old Ubuntu paths, so
  # Claude and Codex sessions keyed to ~/data/... keep working.
  doc = subvol: {
    device = "/dev/data/doc";
    fsType = "btrfs";
    options = [ "noatime" "compress=zstd:3" "ssd" "subvol=/@doc-${subvol}" ];
  };
in
{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];
  networking.hostName = "tron";
  fileSystems."/home/bresilla/data/code" = doc "code";
  fileSystems."/home/bresilla/data/data" = doc "data";
}
