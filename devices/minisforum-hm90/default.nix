{ pkgs, ... }:
{
  imports = [ ../../device-recipes/minisforum-hm90/software/hardware.nix ./storage.nix ./services/gitea.nix ./services/cache.nix ./services/tunnel.nix ../shared/uefi.nix ];
  networking.hostName = "hive";
  boot.swraid.mdadmConf = "MAILADDR root";

  # md0 can assemble just before switch-root, which kills udev's activation of
  # "data" and nothing retries it. Activate it again from the real system.
  systemd.services.activate-data-vg = {
    description = "Activate the data volume group";
    unitConfig.DefaultDependencies = false;
    after = [ "systemd-udevd.service" ];
    before = [ "local-fs-pre.target" ];
    wantedBy = [ "local-fs-pre.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.lvm2.bin pkgs.coreutils ];
    script = ''
      for _ in $(seq 60); do
        vgchange -ay data && exit 0
        sleep 1
      done
      exit 1
    '';
  };

  # Direct cable to nest, for NFS.
  networking.networkmanager.ensureProfiles.profiles.nest-link = {
    connection = { id = "nest-link"; type = "ethernet"; autoconnect-priority = 10; };
    ethernet.mac-address = "1c:83:41:31:2b:56";
    ipv4 = { method = "manual"; address1 = "10.99.0.1/24"; never-default = true; };
    ipv6.method = "disabled";
  };
}
