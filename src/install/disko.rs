use std::fs;
use std::path::Path;

use crate::install::state::{Filesystem, InstallState, Mountpoint, Volume};
use crate::install::storage::{
    StorageDisk, StorageDiskRole, StorageLayout, StorageVolumeGroup,
};
use crate::Result;

/// Read-only view of the layout-level rendering options shared by every disk and
/// volume: the global filesystem, whether physical volumes are LUKS-encrypted,
/// and the btrfs subvolumes carved out of a `/doc` volume.
struct RenderOptions<'a> {
    filesystem: Filesystem,
    encrypt: bool,
    doc_subvolumes: &'a [String],
}

pub fn render(state: &InstallState) -> Result<String> {
    let layout = StorageLayout::from_state(state)?;
    render_layout(&layout)
}

pub fn render_layout(layout: &StorageLayout) -> Result<String> {
    layout.validate()?;

    let options = RenderOptions {
        filesystem: layout.filesystem,
        encrypt: layout.encrypt,
        doc_subvolumes: &layout.doc_subvolumes,
    };

    let mut out = String::new();
    out.push_str("{ lib, ... }:\n\n");
    out.push_str("{\n");
    out.push_str("  disko.devices = lib.mkForce {\n");
    out.push_str("    disk = {\n");
    for disk in &layout.disks {
        if matches!(
            disk.role,
            StorageDiskRole::System | StorageDiskRole::PoolMember
        ) {
            render_disk(&mut out, disk, &options)?;
        }
    }
    // Extra data disks: whole-disk single partition, formatted + mounted.
    for (index, (path, mount)) in layout.data_mounts.iter().enumerate() {
        render_data_disk(&mut out, index, path, mount, &options);
    }
    out.push_str("    };\n");
    out.push_str("    lvm_vg = {\n");
    for volume_group in &layout.volume_groups {
        render_volume_group(&mut out, volume_group, &options)?;
    }
    out.push_str("    };\n");
    out.push_str("  };\n");
    out.push_str("}\n");
    Ok(out)
}

pub fn lvm_vg_names(state: &InstallState) -> Result<Vec<String>> {
    let layout = StorageLayout::from_state(state)?;
    Ok(layout.lvm_vg_names())
}

pub fn write(repo: &Path, state: &InstallState) -> Result<()> {
    let file = repo.join("host/generated/disko.nix");
    let content = render(state)?;
    if let Some(parent) = file.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
    }
    fs::write(&file, content).map_err(|err| format!("failed to write {}: {err}", file.display()))
}

fn render_disk(out: &mut String, disk: &StorageDisk, options: &RenderOptions<'_>) -> Result<()> {
    crate::install::storage::validate_attr(&disk.key)?;
    crate::install::storage::validate_disk_path(&disk.path)?;
    crate::install::storage::validate_attr(&disk.lvm_vg)?;

    out.push_str(&format!("      {} = {{\n", disk.key));
    out.push_str("        type = \"disk\";\n");
    out.push_str(&format!("        device = \"{}\";\n", disk.path));
    out.push_str("        content = {\n");
    out.push_str("          type = \"gpt\";\n");
    out.push_str("          partitions = {\n");
    if disk.create_esp {
        out.push_str("            ESP = {\n");
        out.push_str("              priority = 1;\n");
        out.push_str("              name = \"ESP\";\n");
        out.push_str("              start = \"1MiB\";\n");
        out.push_str(&format!("              end = \"{}MiB\";\n", disk.esp_size_mib));
        out.push_str("              type = \"EF00\";\n");
        out.push_str("              content = {\n");
        out.push_str("                type = \"filesystem\";\n");
        out.push_str("                format = \"vfat\";\n");
        out.push_str("                mountpoint = \"/boot/efi\";\n");
        out.push_str("                mountOptions = [ \"umask=0077\" ];\n");
        out.push_str("              };\n");
        out.push_str("            };\n");
    }
    out.push_str("            lvm = {\n");
    out.push_str("              size = \"100%\";\n");
    if options.encrypt {
        // Wrap the physical volume in LUKS, matching the shell wizard's
        // luks -> lvm_pv nesting. The mapper name is derived from the disk key.
        out.push_str("              content = {\n");
        out.push_str("                type = \"luks\";\n");
        out.push_str(&format!("                name = \"luks_{}\";\n", disk.key));
        out.push_str("                settings.allowDiscards = true;\n");
        out.push_str("                content = {\n");
        out.push_str("                  type = \"lvm_pv\";\n");
        out.push_str(&format!("                  vg = \"{}\";\n", disk.lvm_vg));
        out.push_str("                };\n");
        out.push_str("              };\n");
    } else {
        out.push_str("              content = {\n");
        out.push_str("                type = \"lvm_pv\";\n");
        out.push_str(&format!("                vg = \"{}\";\n", disk.lvm_vg));
        out.push_str("              };\n");
    }
    out.push_str("            };\n");
    out.push_str("          };\n");
    out.push_str("        };\n");
    out.push_str("      };\n");
    Ok(())
}

/// A non-install data disk: whole disk, single partition, formatted with the
/// chosen filesystem and mounted at `mount`.
fn render_data_disk(
    out: &mut String,
    index: usize,
    path: &str,
    mount: &str,
    options: &RenderOptions<'_>,
) {
    let format = match options.filesystem {
        Filesystem::Btrfs => "btrfs",
        Filesystem::Ext4 => "ext4",
    };
    out.push_str(&format!("      data{index} = {{\n"));
    out.push_str("        type = \"disk\";\n");
    out.push_str(&format!("        device = \"{path}\";\n"));
    out.push_str("        content = {\n");
    out.push_str("          type = \"gpt\";\n");
    out.push_str("          partitions = {\n");
    out.push_str("            data = {\n");
    out.push_str("              size = \"100%\";\n");
    out.push_str("              content = {\n");
    out.push_str("                type = \"filesystem\";\n");
    out.push_str(&format!("                format = \"{format}\";\n"));
    out.push_str(&format!("                mountpoint = \"{mount}\";\n"));
    out.push_str("              };\n");
    out.push_str("            };\n");
    out.push_str("          };\n");
    out.push_str("        };\n");
    out.push_str("      };\n");
}

fn render_volume_group(
    out: &mut String,
    volume_group: &StorageVolumeGroup,
    options: &RenderOptions<'_>,
) -> Result<()> {
    crate::install::storage::validate_attr(&volume_group.name)?;

    out.push_str(&format!("      {} = {{\n", volume_group.name));
    out.push_str("        type = \"lvm_vg\";\n");
    out.push_str("        lvs = {\n");
    for volume in &volume_group.logical_volumes {
        render_volume(out, volume, options)?;
    }
    out.push_str("        };\n");
    out.push_str("      };\n");
    Ok(())
}

fn render_volume(out: &mut String, volume: &Volume, options: &RenderOptions<'_>) -> Result<()> {
    crate::install::storage::validate_attr(&volume.name)?;
    out.push_str(&format!("          {} = {{\n", volume.name));
    out.push_str(&format!("            size = \"{}G\";\n", volume.size_gib));
    match &volume.mountpoint {
        Mountpoint::Swap => {
            out.push_str("            content = {\n");
            out.push_str("              type = \"swap\";\n");
            out.push_str(&format!(
                "              extraArgs = [ \"-L\" \"{}\" ];\n",
                volume.name
            ));
            out.push_str("              resumeDevice = true;\n");
            out.push_str("            };\n");
        }
        Mountpoint::Path(path) => match options.filesystem {
            Filesystem::Ext4 => render_ext4_volume(out, path),
            Filesystem::Btrfs if path == "/doc" && !options.doc_subvolumes.is_empty() => {
                render_doc_btrfs_volume(out, volume, options.doc_subvolumes)
            }
            Filesystem::Btrfs => render_btrfs_volume(out, volume, path),
        },
    }
    out.push_str("          };\n");
    Ok(())
}

fn render_ext4_volume(out: &mut String, path: &str) {
    out.push_str("            content = {\n");
    out.push_str("              type = \"filesystem\";\n");
    out.push_str("              format = \"ext4\";\n");
    out.push_str(&format!("              mountpoint = \"{}\";\n", path));
    out.push_str("            };\n");
}

fn render_btrfs_volume(out: &mut String, volume: &Volume, path: &str) {
    out.push_str("            content = {\n");
    out.push_str("              type = \"btrfs\";\n");
    out.push_str(&format!(
        "              extraArgs = [ \"-f\" \"-L\" \"{}\" ];\n",
        volume.name
    ));
    out.push_str("              subvolumes = {\n");
    out.push_str(&format!("                \"/@{}\" = {{\n", volume.name));
    out.push_str(&format!("                  mountpoint = \"{}\";\n", path));
    push_btrfs_mount_options(out, "                  ");
    out.push_str("                };\n");
    out.push_str("              };\n");
    out.push_str("            };\n");
}

fn render_doc_btrfs_volume(out: &mut String, volume: &Volume, subvolumes: &[String]) {
    out.push_str("            content = {\n");
    out.push_str("              type = \"btrfs\";\n");
    out.push_str(&format!(
        "              extraArgs = [ \"-f\" \"-L\" \"{}\" ];\n",
        volume.name
    ));
    out.push_str("              subvolumes = {\n");
    for subvol in subvolumes {
        out.push_str(&format!("                \"/{}\" = {{\n", subvol));
        out.push_str(&format!("                  mountpoint = \"/doc/{}\";\n", subvol));
        push_btrfs_mount_options(out, "                  ");
        out.push_str("                };\n");
    }
    out.push_str("              };\n");
    out.push_str("            };\n");
}

fn push_btrfs_mount_options(out: &mut String, indent: &str) {
    out.push_str(&format!("{indent}mountOptions = [\n"));
    out.push_str(&format!("{indent}  \"noatime\"\n"));
    out.push_str(&format!("{indent}  \"compress=zstd:3\"\n"));
    out.push_str(&format!("{indent}  \"ssd\"\n"));
    out.push_str(&format!("{indent}  \"space_cache=v2\"\n"));
    out.push_str(&format!("{indent}];\n"));
}

#[cfg(test)]
mod tests {
    use super::{lvm_vg_names, render};
    use crate::install::state::{DiskChoice, InstallState};

    #[test]
    fn renders_root_mountpoint_without_rejecting_slash() {
        let output = render(&InstallState::sample()).unwrap();
        assert!(output.contains("mountpoint = \"/\";"));
    }

    #[test]
    fn renders_lvm_pool_and_swap() {
        let output = render(&InstallState::sample()).unwrap();
        assert!(output.contains("lvm_vg = {"));
        assert!(output.contains("pool = {"));
        assert!(output.contains("type = \"swap\";"));
    }

    #[test]
    fn exposes_lvm_vg_names_for_destructive_cleanup() {
        let names = lvm_vg_names(&InstallState::sample()).unwrap();

        assert_eq!(names, vec!["pool".to_string()]);
    }

    #[test]
    fn rejects_over_capacity_layout() {
        let mut state = InstallState::sample();
        state.disks[0].size_gib = 100;
        state.discovered_disks[0].size_gib = 100;
        let err = render(&state).unwrap_err();
        assert!(err.contains("volume group pool uses"));
    }

    #[test]
    fn renders_ext4_volumes_when_filesystem_is_ext4() {
        let mut state = InstallState::sample();
        state.filesystem = crate::install::state::Filesystem::Ext4;

        let output = render(&state).unwrap();

        assert!(output.contains("format = \"ext4\";"));
        assert!(output.contains("mountpoint = \"/\";"));
        assert!(!output.contains("type = \"btrfs\";"));
        // swap is unaffected by the filesystem choice
        assert!(output.contains("type = \"swap\";"));
    }

    #[test]
    fn renders_luks_wrapped_pv_when_encryption_enabled() {
        let mut state = InstallState::sample();
        state.encrypt = true;

        let output = render(&state).unwrap();

        assert!(output.contains("type = \"luks\";"));
        assert!(output.contains("name = \"luks_nvme0n1\";"));
        assert!(output.contains("settings.allowDiscards = true;"));
        // luks must nest the lvm_pv, not replace it
        let luks_at = output.find("type = \"luks\";").unwrap();
        let pv_at = output.find("type = \"lvm_pv\";").unwrap();
        assert!(luks_at < pv_at);
    }

    #[test]
    fn renders_doc_volume_with_multiple_subvolumes() {
        let output = render(&InstallState::sample()).unwrap();

        assert!(output.contains("mountpoint = \"/doc/code\";"));
        assert!(output.contains("mountpoint = \"/doc/data\";"));
        assert!(output.contains("mountpoint = \"/doc/self\";"));
        assert!(output.contains("mountpoint = \"/doc/work\";"));
        assert!(output.contains("\"/code\" = {"));
    }

    #[test]
    fn renders_multiple_selected_disks_as_joined_lvm_pool() {
        let mut state = InstallState::sample();
        let second_disk = DiskChoice {
            path: "/dev/nvme1n1".to_string(),
            size_gib: 465,
            model: None,
        };
        state.discovered_disks.push(second_disk.clone());
        state.disks.push(second_disk.clone());
        state.disk_roles.insert(
            second_disk.path.clone(),
            crate::install::state::DiskRole::PoolMember,
        );
        state.normalize_disk_roles();

        let output = render(&state).unwrap();

        assert!(output.contains("nvme0n1 = {"));
        assert!(output.contains("device = \"/dev/nvme0n1\";"));
        assert!(output.contains("ESP = {"));
        assert!(output.contains("nvme1n1 = {"));
        assert!(output.contains("device = \"/dev/nvme1n1\";"));
        assert_eq!(output.matches("vg = \"pool\";").count(), 2);
    }
}
