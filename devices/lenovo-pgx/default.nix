{
  imports = [
    ../../device-recipes/lenovo-pgx/software/hardware.nix
    ../../device-recipes/lenovo-pgx/software/dgx-spark.nix
    ./storage.nix
    ../shared/uefi.nix
  ];
  networking.hostName = "lama";
  bresilla.nix.buildOnTron = true;
  # Builds aarch64 for CI.
  bresilla.nix.serveBuilds = true;
  bresilla.nix.ciBuilder.address = "10.77.0.9";
}
