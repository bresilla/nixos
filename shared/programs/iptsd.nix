{ config, lib, pkgs, bresilla, ... }:
{
  options.bresilla.programs.iptsd.enable =
    lib.mkEnableOption "iptsd with a configurable delay before restoring touch after pen use";

  config = lib.mkIf config.bresilla.programs.iptsd.enable {
    # The upstream module uses pkgs.iptsd for its service and udev rules.
    nixpkgs.overlays = [ (_final: _prev: {
      iptsd = bresilla.iptsd or (throw "Patched iptsd is not cached yet; build and publish packages#iptsd first");
    }) ];
    services.iptsd.enable = true;

    # logind reprocesses uaccess devices at login. Keep the systemd tag on change
    # too, or the upstream add-only rule lets systemd stop the device-bound daemon.
    services.udev.extraRules = ''
      SUBSYSTEM=="hidraw", ACTION=="change", TAG+="systemd", \
        PROGRAM="${pkgs.iptsd}/bin/iptsd-check-device --quiet $env{DEVNAME}", \
        PROGRAM="${pkgs.systemd}/bin/systemd-escape --path $env{DEVNAME}", \
        ENV{SYSTEMD_WANTS}+="iptsd@$result.service"
    '';
  };
}
