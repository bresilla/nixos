# Storage Design

The Rust installer now has an initial `StorageLayout` model. The current default
layout is still intentionally simple:

- selected install disks
- one GPT
- one ESP on the first disk
- one LVM PV per selected disk
- one LVM VG named `pool`
- fixed logical volumes rendered from `InstallState.volumes`

That is enough for the first rewrite, but the UI still needs explicit control
over which discovered disks are selected and which storage mode is being used.

## Target Model

Storage should be represented as explicit objects:

- `Disk`: path, role, wipe policy, partition table, selected/not selected
- `Partition`: name, size expression, type, content
- `PhysicalVolume`: disk partition to VG membership
- `VolumeGroup`: name, PV members, allocation policy
- `LogicalVolume`: name, size, filesystem/swap, mountpoint, mount options
- `Filesystem`: type, label, subvolumes, format args, mount options

The installer must render Disko from this model, not from scattered string constants.

Disk roles:

- `system`: participates in system install; first system disk owns the ESP
- `pool-member`: joins an LVM pool without creating an ESP
- `data`: known data disk, managed outside the system Disko layout
- `reserve`: known disk intentionally left as-is
- `ignore`: never touch

Storage actions:

- `wipe-disk`
- `create-esp`
- `join-volume-group`
- `format-logical-volume`
- `leave-existing`
- `ignore`

## Multi-Disk Modes

Supported modes should be explicit:

- `single-disk`: current behavior
- `joined-lvm`: multiple disks become PVs in one VG
- `separate-pools`: each selected disk gets its own VG
- `manual`: user defines disks, partitions, VGs, LVs directly

For `joined-lvm`, the UI must show the failure tradeoff clearly: losing one disk can lose the whole VG unless the user chooses a redundant layer outside plain LVM.

## Overwrite Behavior

Overwrite mode must derive destructive cleanup from the rendered storage model:

- remove all target VG names
- wipe selected target disks
- avoid touching non-target disks unless their VG names conflict with the target model and overwrite mode is explicitly enabled
- include every VG name in the destructive confirmation phrase

No hardcoded VG names should exist outside the storage model.

## UI Requirements

The Disk step should become a storage editor with these views:

- discovered disks
- selected disks
- pool/VG assignment
- volume list
- capacity review per pool
- destructive cleanup preview

The confirmation page should show:

- disks to wipe
- VGs to remove
- mountpoints to create
- free capacity per VG

## Implemented

- `StorageLayout` exists separately from `InstallState`.
- Disko rendering reads from `StorageLayout`.
- Overwrite confirmation and plan cleanup read VG names from `StorageLayout`.
- Multiple selected disks render as one joined LVM pool.
- Storage disks have explicit roles.
- Storage layouts can produce a high-level action list.
- Installer state separates discovered disks from selected install disks.
- The Disk UI marks selected disks as `[S]` system or `[P]` pool member.
- The Disk UI can cycle disk roles between system, pool, data, reserve, and ignore.
- `StorageMode` exists in installer state and layout validation.
- The TUI can switch between the currently rendered modes: `single-disk` and `joined-lvm`.
- Installer state has user-defined volume groups.
- Installer state tracks disk-to-volume-group and logical-volume-to-volume-group assignment.
- `StorageLayout` uses those assignments and validates capacity per volume group.
- The Disk UI shows and can cycle the selected install disk's volume group.
- The Volume UI shows each logical volume's volume group and can cycle it with `+/-`.
- The TUI can create a new volume group from a disk/volume pool field with `+`.
- The TUI can rename the current volume group by typing on a pool field.
- The TUI can delete a non-default volume group with `-`, reassigning its disks and logical volumes to the default group.
- The wizard has a dedicated `pools` step with selected-pool state.
- The `pools` step can create, rename, select, and delete pools directly.
- The pool panel shows per-pool capacity plus assigned disks and logical volumes.
- The summary panel shows per-pool used, total, and free capacity.
- `StorageAction` has human-readable labels and destructive/non-destructive classification.
- The summary and confirmation views show storage action previews, including overwrite VG removals.
- The generator writes `generated/storage-plan.json`.
- The generated storage plan records target metadata, storage mode, disk roles, VG assignments, logical volume assignments, and action previews.
- Remote generated artifact transfer includes `storage-plan.json`.
- Hidden `nx storage plan` prints the generated storage plan for development/testing.
- The installer TUI has a dedicated storage plan review step before destructive confirmation.
- Hidden `nx storage apply --dry-run` previews generated storage actions and refuses execution.
- Confirmed remote installs now route through the Rust remote agent executor instead of
  the old shell backend. The local confirmed path still uses `install.sh`.
- Confirmed Rust remote installs decrypt the shared system age key once into a RAM
  cache, then copy it to `/mnt/var/lib/sops-nix/key.txt` before `nixos-install`.
- The Rust remote finish plan now hardens `/mnt/etc/nixos`, keeps the GitHub token on
  stdin for system `bin ensure`, and schedules reboot with a delayed remote script.
- Optional dotfiles are now part of the Rust remote finish plan. The remote agent
  clones the dotfiles repo, copies it into `/mnt/home/<user>/.dot`, runs `run_me.sh`
  inside `nixos-enter`, and repairs user-owned paths afterward.

## Immediate Next Implementation

1. Exercise the full Rust remote install path on a disposable target.
2. Start shrinking the shell installer now that the Rust path covers the remote
   finish flow.
3. Add typed storage action execution behind the TUI confirmation gate.
