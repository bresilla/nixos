{ config, lib, pkgs, utils, ... }:

let
  # The data subvolumes disko declares, so a live system gets new ones without a reinstall.
  subvolumes = config.disko.devices.lvm_vg.data.lvs.store.content.subvolumes;
  mountpoints = lib.mapAttrsToList (_: v: v.mountpoint) subvolumes;
  # hive's gitea container shifts its uid 3000 by 524288; NFS keeps numeric owners.
  owners = { "/@gitea" = "527288:527288"; };
in {
  systemd.services.data-subvolumes = {
    description = "Create missing data subvolumes and set their owners";
    unitConfig.DefaultDependencies = false;
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
      ${lib.concatStrings (lib.mapAttrsToList (subvolume: owner: ''
        chown ${owner} "$top${subvolume}" && chmod 0750 "$top${subvolume}"
      '') owners)}
    '';
  };

  # Each data mount waits for that service; nofail from disko still keeps boot going.
  fileSystems = lib.genAttrs mountpoints (_: {
    options = [ "x-systemd.requires=data-subvolumes.service" "x-systemd.after=data-subvolumes.service" ];
  });
}
