{ lib, ... }:
let
  nestDump = lib.importJSON ../nest/dump.json;
  nestLink = lib.importJSON ../nest/link.json;
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
  # nest pushes dump copies here over SSH (the disk itself is picked on status.bresilla.com).
  bresilla.dump.target = { enable = true; managerKey = nestDump.key; managerFrom = nestDump.from ++ [ nestLink.nest ]; };
  bresilla.nix.serveBuilds = true;
  bresilla.nix.ciBuilder = { enable = true; tunnel = (lib.importJSON ./ci-builder.json).address; cores = 12; maxJobs = 2; jobFeatures = [ "userns" "kvm" ]; };
  fileSystems."/home/bresilla/data/code" = doc "code";
  fileSystems."/home/bresilla/data/data" = doc "data";
}
