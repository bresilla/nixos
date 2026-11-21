{ pkgs, ... }:
{
  imports = [ ../../device-recipes/minisforum-hm90/software/hardware.nix ./storage.nix ../../services ../shared/uefi.nix ];
  networking.hostName = "hive";

  # The services hive hosts (services/), and the modules its own hardware uses.
  bresilla.server = {
    tunnel.enable = true;
    gitea.enable = true;
    cache.enable = true;
    ci.enable = true;
    id.enable = true;
    s3.enable = true;
    vault.enable = true;
    ca.enable = true;
    net.enable = true;
    status.enable = true;
    kernelModules = ./modules.txt;
    # The two YubiKeys gopass encrypts to: hive's own secrets go out only this way.
    recipients = [
      "age1yubikey1q03sjfgkj7l25va4uhh87gtm5dj3a5f27497ghyrpdzzqe8uagjf5ehtkjf"
      "age1yubikey1qdj8xer5fmxh6nxnenpfkw20l0ekmr9nzhfe2xpcsrdctv7u63pj2r62rzc"
    ];
  };
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
