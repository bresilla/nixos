# LIS storage → disko devices. Pure translation of the document this repo's
# installer (nox) emits: GPT disks, an ESP on the system disk, one LVM PV per
# pool slice (optionally LUKS-wrapped), and per-volume filesystems.
{ lib, doc }:

let
  storage = doc.storage or { };
  partitions = storage.partitions or [ ];
  encryption = storage.encryption or [ ];
  lvmGroups = storage.lvm or [ ];

  gib = size:
    if lib.hasSuffix "GiB" size then
      lib.toInt (lib.removeSuffix "GiB" size)
    else if lib.hasSuffix "MiB" size then
      (lib.toInt (lib.removeSuffix "MiB" size)) / 1024
    else
      throw "lis: unsupported size ${size}";
  mib = size:
    if lib.hasSuffix "MiB" size then
      lib.toInt (lib.removeSuffix "MiB" size)
    else
      (gib size) * 1024;

  # partition id → pool (VG), resolving LUKS containers to what they cover.
  cryptOver = lib.listToAttrs (map (c: lib.nameValuePair c.id c.over) encryption);
  poolOfPart = lib.listToAttrs (lib.concatMap
    (group: map
      (dev: lib.nameValuePair (cryptOver.${dev} or dev) group.name)
      group.devices)
    lvmGroups);
  encrypted = part: lib.any (c: c.over == (part.id or "")) encryption;

  espFor = diskId: lib.findFirst
    (p: p.disk == diskId && (p.role or "") == "esp")
    null
    partitions;
  pvsFor = diskId: lib.filter
    (p: p.disk == diskId && (p.role or "") != "esp" && poolOfPart ? ${p.id or "?"})
    partitions;

  renderPv = diskId: isLast: part:
    let pool = poolOfPart.${part.id}; in
    lib.nameValuePair "pv_${pool}" {
      size = if isLast then "100%" else "${toString (gib part.size)}G";
      content =
        let pv = { type = "lvm_pv"; vg = pool; }; in
        if encrypted part then {
          type = "luks";
          name = "luks_${diskId}_${pool}";
          settings.allowDiscards = true;
          content = pv;
        } else
          pv;
    };

  renderDisk = disk:
    let
      esp = espFor disk.id;
      pvs = pvsFor disk.id;
      lastIndex = (lib.length pvs) - 1;
    in
    lib.nameValuePair disk.id {
      type = "disk";
      device = disk.match.path;
      content = {
        type = "gpt";
        partitions =
          (lib.optionalAttrs (esp != null) {
            ESP = {
              priority = 1;
              name = "ESP";
              start = "1MiB";
              end = "${toString (mib esp.size)}MiB";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot/efi";
                mountOptions = [ "umask=0077" ];
              };
            };
          })
          // (lib.listToAttrs (lib.imap0
            (i: part: renderPv disk.id (i == lastIndex) part)
            pvs));
      };
    };

  btrfsMountOptions = [ "noatime" "compress=zstd:3" "ssd" "space_cache=v2" ];

  renderVolume = fillGib: vol:
    let
      isRest = (vol.size or "rest") == "rest";
      sizeG = if isRest then fillGib else gib vol.size;
      fs = vol.fs or "btrfs";
      content =
        if fs == "swap" then {
          type = "swap";
          extraArgs = [ "-L" vol.name ];
          resumeDevice = true;
        } else if fs == "btrfs" then {
          type = "btrfs";
          extraArgs = [ "-f" "-L" vol.name ];
          subvolumes =
            {
              "/@${vol.name}" = {
                mountpoint = vol.mountpoint;
                mountOptions = btrfsMountOptions;
              };
            }
            // (lib.listToAttrs (map
              (sub: lib.nameValuePair "/@${sub.name}" {
                mountpoint = sub.mountpoint;
                mountOptions = btrfsMountOptions;
              })
              (vol.subvolumes or [ ])));
        } else {
          type = "filesystem";
          format = fs;
          mountpoint = vol.mountpoint;
        };
    in
    lib.nameValuePair vol.name {
      size = "${toString sizeG}G";
      inherit content;
    };

  renderGroup = group:
    let
      capacity = lib.foldl' lib.add 0 (map
        (dev:
          let part = lib.findFirst (p: (p.id or "") == (cryptOver.${dev} or dev)) null partitions;
          in if part == null then 0 else gib part.size)
        group.devices);
      fixed = lib.foldl' lib.add 0 (map
        (vol: if (vol.size or "rest") == "rest" then 0 else gib vol.size)
        group.volumes);
      fillGib = lib.max 1 (capacity - fixed - 1);
    in
    lib.nameValuePair group.name {
      type = "lvm_vg";
      lvs = lib.listToAttrs (map (renderVolume fillGib) group.volumes);
    };
in
{
  disk = lib.listToAttrs (map renderDisk (doc.target.disks or [ ]));
  lvm_vg = lib.listToAttrs (map renderGroup lvmGroups);
}
