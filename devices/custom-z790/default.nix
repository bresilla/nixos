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
    ../../device-recipes/custom-z790/software/hardware.nix
    ../shared/uefi.nix
    ./storage.nix
  ];
  networking.hostName = "tron";
  bresilla.nix.serveBuilds = true;
  fileSystems."/home/bresilla/data/code" = doc "code";
  fileSystems."/home/bresilla/data/data" = doc "data";
}
