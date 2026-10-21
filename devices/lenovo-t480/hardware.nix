{ modulesPath, pkgs, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ../shared/uefi.nix
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
  bresilla.features.system = {
    architecture = "x86_64";
    cpuVendor = "intel";
  };
  boot.resumeDevice = "/dev/pool/swap";
  boot.kernelParams = [
    "mem_sleep_default=deep"
    "thinkpad_acpi.force_load=1"
  ];
  boot.kernelModules = [ "thinkpad_acpi" ];

  # With coreboot, loading thinkpad_acpi can soft-block Wi-Fi.
  systemd.services.thinkpad-wifi-unblock = {
    description = "Unblock Wi-Fi after loading the ThinkPad driver";
    wantedBy = [ "multi-user.target" ];
    requires = [ "systemd-modules-load.service" ];
    after = [ "systemd-modules-load.service" "systemd-rfkill.service" ];
    before = [ "NetworkManager.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.util-linux}/bin/rfkill unblock wifi";
    };
  };
}
