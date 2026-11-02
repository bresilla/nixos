{ config, lib, bresilla, ... }:
{
  options.bresilla.programs.iptsd.enable =
    lib.mkEnableOption "iptsd with a configurable delay before restoring touch after pen use";

  config = lib.mkIf config.bresilla.programs.iptsd.enable {
    # The upstream module uses pkgs.iptsd for its service and udev rules.
    nixpkgs.overlays = [ (_final: _prev: {
      iptsd = bresilla.iptsd or (throw "Patched iptsd is not cached yet; build and publish packages#iptsd first");
    }) ];
    services.iptsd.enable = true;
  };
}
