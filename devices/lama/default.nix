{ lib, ... }:
{
  imports = [
    ../../device-recipes/lenovo-pgx/software/hardware.nix
    ../../device-recipes/lenovo-pgx/software/dgx-spark.nix
    ./storage.nix
    ../shared/uefi.nix
  ];
  networking.hostName = "lama";
  # No containers on this machine.
  virtualisation.podman.enable = lib.mkForce false;
  hardware.nvidia-container-toolkit.enable = lib.mkForce false;
  bresilla.nix.buildOnTron = true;
  # Builds for its devices and for CI.
  bresilla.nix.serveBuilds = true;
  bresilla.nix.ciBuilder = { enable = true; tunnel = (lib.importJSON ./ci-builder.json).address; cores = 10; maxJobs = 2; };
}
