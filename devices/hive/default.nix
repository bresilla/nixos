{ lib, pkgs, ... }:
let
  link = lib.importJSON ../nest/link.json;
in
{
  imports = [ ../../device-recipes/minisforum-hm90/software/hardware.nix ../../device-recipes/minisforum-hm90/software/thermal.nix ./storage.nix ../../services ];
  networking.hostName = "hive";

  # The services hive hosts (services/), and the modules its own hardware uses.
  bresilla.server = {
    tunnel = { enable = true; id = "12c748bd-aa30-49a8-a0d4-2bb7f21267de"; credentials = "/var/lib/cloudflared-hive-nix.json"; };
    gitea.enable = true;
    cache.enable = true;
    ci.enable = true;
    id.enable = true;
    s3.enable = true;
    vault.enable = true;
    ca.enable = true;
    net.enable = true;
    status.enable = true;
    skill.enable = true;
    kernelModules = ./modules.txt;
    uplink = "enp4s0";
    storage.host = "nest.link";
    overlay.address = (lib.importJSON ./device.json).netbird;
    # The two YubiKeys gopass encrypts to: hive's own secrets go out only this way.
    recipients = import ../../shared/users/recipients.nix;
  };

  # dump's hub, on the cable to nest; the status page edits its target list.
  bresilla.dump.hub = { enable = true; address = link.hive; manager = link.nest; };

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
    ipv4 = { method = "manual"; address1 = "${link.hive}/${toString link.prefix}"; never-default = true; };
    ipv6.method = "disabled";
  };
}
