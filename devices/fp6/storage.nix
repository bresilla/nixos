{ config, pkgs, modulesPath, ... }:
let registration = pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; };
in {
  imports = [ (modulesPath + "/image/repart.nix") ];
  boot.initrd.systemd.services.fp6-userdata = {
    description = "Expose the nested userdata partitions";
    wantedBy = [ "initrd-root-device.target" ];
    requiredBy = [ "sysroot.mount" ];
    before = [ "sysroot.mount" "initrd-root-device.target" ];
    after = [ "systemd-udev-trigger.service" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 60; };
    script = ''
      # userdata contains a nested 4096-byte-sector GPT, as on postmarketOS.
      for attempt in $(seq 1 30); do
        [ -b /dev/disk/by-partlabel/userdata ] && break
        sleep 1
      done
      losetup --partscan --find --nooverlap --sector-size 4096 /dev/disk/by-partlabel/userdata
      udevadm trigger --subsystem-match=block
      udevadm settle
    '';
  };
  fileSystems = {
    "/" = { device = "/dev/disk/by-label/nixos-fp6"; fsType = "ext4"; autoResize = true; };
    "/boot" = { device = "/dev/disk/by-label/FP6-BOOT"; fsType = "vfat"; };
  };
  systemd.repart = { enable = true; partitions."03-root".Type = "root"; };
  boot.postBootCommands = ''
    if [ -f /nix-path-registration ]; then
      ${config.nix.package}/bin/nix-store --load-db < /nix-path-registration
      ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
      rm /nix-path-registration
    fi
  '';
  image.repart = {
    name = "fp6-userdata";
    version = null;
    sectorSize = 4096;
    compression.enable = false;
    partitions = {
      "00-padding".repartConfig = { Type = "linux-generic"; SizeMinBytes = "15M"; SizeMaxBytes = "15M"; };
      "10-boot" = {
        contents."/README".source = pkgs.writeText "fp6-boot-note" "The boot image is built separately as fp6-boot.\n";
        # FAT32 needs at least 65525 clusters, including with 4 KiB sectors.
        repartConfig = { Type = "esp"; Format = "vfat"; Label = "FP6-BOOT"; FileSystemSectorSize = 4096; SizeMinBytes = "512M"; SizeMaxBytes = "512M"; };
      };
      "20-root" = {
        storePaths = [ config.system.build.toplevel ];
        contents = {
          "/boot".source = pkgs.runCommand "fp6-boot-mountpoint" { } "mkdir $out";
          "/nix-path-registration".source = "${registration}/registration";
        };
        repartConfig = { Type = "root"; Format = "ext4"; Label = "nixos-fp6"; FileSystemSectorSize = 4096; Minimize = "guess"; GrowFileSystem = true; };
      };
    };
  };
}
