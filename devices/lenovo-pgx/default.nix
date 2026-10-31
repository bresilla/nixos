{
  imports = [
    ../../device-recipes/lenovo-pgx/software/hardware.nix
    ../../device-recipes/lenovo-pgx/software/dgx-spark.nix
    ./storage.nix
    ../shared/uefi.nix
  ];
  networking.hostName = "lama";
  bresilla.nix.buildOnTron = true;
}
