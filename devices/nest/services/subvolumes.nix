{ config, lib, pkgs, utils, ... }:

let
  # The data subvolumes disko declares, so a live system gets new ones without a reinstall.
  subvolumes = config.disko.devices.lvm_vg.data.lvs.store.content.subvolumes;
  mountpoints = lib.mapAttrsToList (_: v: v.mountpoint) subvolumes;
  # hive's containers shift their uids by 524288 (gitea 3000, atticd 3001, rustfs 3002); NFS keeps numeric owners.
  owners = {
    "/@id" = "0:0"; "/@s3" = "527290:527290";
    "/@build" = "0:0"; "/@vault" = "0:0"; "/@net" = "0:0"; "/@git" = "527288:527288"; "/@cache" = "527289:527289";
    "/@cache-chunks" = "527289:527289";
  };
  # Shares in the config/data layout (MIGRATE.md): config/ is root's alone, data/ the service's.
  split = [ "/@git" "/@cache" "/@id" "/@s3" "/@build" "/@vault" "/@net" ];
in {
  systemd.services.data-subvolumes = {
    description = "Create missing data subvolumes and set their owners";
    unitConfig.DefaultDependencies = false;
    # Also on a switch, not only when a mount pulls it in at boot.
    wantedBy = [ "local-fs.target" ];
    requires = [ "dev-data-store.device" ];
    after = [ "dev-data-store.device" ];
    before = map (m: "${utils.escapeSystemdPath m}.mount") mountpoints;
    path = [ pkgs.btrfs-progs pkgs.util-linux pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      top=$(mktemp -d)
      mount -o subvol=/ /dev/data/store "$top"
      trap 'umount "$top"; rmdir "$top"' EXIT
      for subvolume in ${lib.concatStringsSep " " (lib.attrNames subvolumes)}; do
        [ -e "$top$subvolume" ] || btrfs subvolume create "$top$subvolume"
      done
      # btrbk's snapshots of every share (services/backup.nix).
      install -d -o 0 -g 0 -m 0700 "$top/.snapshots"
      ${lib.concatStrings (lib.mapAttrsToList (subvolume: owner: ''
        chown ${owner} "$top${subvolume}" && chmod 0750 "$top${subvolume}"
      '') owners)}
      ${lib.concatMapStrings (subvolume: ''
        install -d -o 0 -g 0 -m 0700 "$top${subvolume}/config"
        [ -d "$top${subvolume}/data" ] || install -d -m 0750 "$top${subvolume}/data"
        chown ${owners.${subvolume}} "$top${subvolume}/data"
      '') split}
    '';
  };

  # Each data mount waits for that service; nofail from disko still keeps boot going.
  fileSystems = lib.genAttrs mountpoints (_: {
    options = [ "x-systemd.requires=data-subvolumes.service" "x-systemd.after=data-subvolumes.service" ];
  });
}
