{
  imports = [
    ../../device-recipes/lenovo-pgx/software/hardware.nix
    ../../device-recipes/lenovo-pgx/software/dgx-spark.nix
    ./storage.nix
    ../shared/uefi.nix
  ];
  networking.hostName = "lama";
  bresilla.nix.buildOnTron = true;
  # Builds for its devices and for CI.
  bresilla.nix.serveBuilds = true;
  bresilla.nix.ciBuilder = { enable = true; tunnel = "10.77.0.9"; };
}
