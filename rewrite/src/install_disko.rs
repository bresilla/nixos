use std::fs;
use std::path::Path;

use crate::install_state::{InstallState, Mountpoint, Volume};
use crate::install_storage::{
    self, StorageDisk, StorageDiskRole, StorageLayout, StorageVolumeGroup,
};
use crate::Result;

pub fn render(state: &InstallState) -> Result<String> {
    let layout = StorageLayout::from_state(state)?;
    render_layout(&layout)
}

pub fn render_layout(layout: &StorageLayout) -> Result<String> {
    layout.validate()?;

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
            render_disk(&mut out, disk)?;
        }
    }
    out.push_str("    };\n");
    out.push_str("    lvm_vg = {\n");
    for volume_group in &layout.volume_groups {
        render_volume_group(&mut out, volume_group)?;
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
    let file = repo.join("generated/disko.nix");
    let content = render(state)?;
    if let Some(parent) = file.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
    }
    fs::write(&file, content).map_err(|err| format!("failed to write {}: {err}", file.display()))
}

fn render_disk(out: &mut String, disk: &StorageDisk) -> Result<()> {
    install_storage::validate_attr(&disk.key)?;
    install_storage::validate_disk_path(&disk.path)?;
    install_storage::validate_attr(&disk.lvm_vg)?;

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
        out.push_str("              end = \"1024MiB\";\n");
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
    out.push_str("              content = {\n");
    out.push_str("                type = \"lvm_pv\";\n");
    out.push_str(&format!("                vg = \"{}\";\n", disk.lvm_vg));
    out.push_str("              };\n");
    out.push_str("            };\n");
    out.push_str("          };\n");
    out.push_str("        };\n");
    out.push_str("      };\n");
    Ok(())
}

fn render_volume_group(out: &mut String, volume_group: &StorageVolumeGroup) -> Result<()> {
    install_storage::validate_attr(&volume_group.name)?;

    out.push_str(&format!("      {} = {{\n", volume_group.name));
    out.push_str("        type = \"lvm_vg\";\n");
    out.push_str("        lvs = {\n");
    for volume in &volume_group.logical_volumes {
        render_volume(out, volume)?;
    }
    out.push_str("        };\n");
    out.push_str("      };\n");
    Ok(())
}

fn render_volume(out: &mut String, volume: &Volume) -> Result<()> {
    install_storage::validate_attr(&volume.name)?;
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
        Mountpoint::Path(path) => {
            out.push_str("            content = {\n");
            out.push_str("              type = \"btrfs\";\n");
            out.push_str(&format!(
                "              extraArgs = [ \"-f\" \"-L\" \"{}\" ];\n",
                volume.name
            ));
            out.push_str("              subvolumes = {\n");
            out.push_str(&format!("                \"/@{}\" = {{\n", volume.name));
            out.push_str(&format!("                  mountpoint = \"{}\";\n", path));
            out.push_str("                  mountOptions = [\n");
            out.push_str("                    \"noatime\"\n");
            out.push_str("                    \"compress=zstd:3\"\n");
            out.push_str("                    \"ssd\"\n");
            out.push_str("                    \"space_cache=v2\"\n");
            out.push_str("                  ];\n");
            out.push_str("                };\n");
            out.push_str("              };\n");
            out.push_str("            };\n");
        }
    }
    out.push_str("          };\n");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{lvm_vg_names, render};
    use crate::install_state::{DiskChoice, InstallState};

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
            crate::install_state::DiskRole::PoolMember,
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
