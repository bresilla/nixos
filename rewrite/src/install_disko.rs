use std::fs;
use std::path::Path;

use crate::install_state::{InstallState, Mountpoint, Volume};
use crate::Result;

pub fn render(state: &InstallState) -> Result<String> {
    validate(state)?;

    let disk = state
        .disks
        .first()
        .ok_or_else(|| "at least one install disk is required".to_string())?;
    let disk_key = disk_key(&disk.path)?;

    let mut out = String::new();
    out.push_str("{ lib, ... }:\n\n");
    out.push_str("{\n");
    out.push_str("  disko.devices = lib.mkForce {\n");
    out.push_str("    disk = {\n");
    out.push_str(&format!("      {disk_key} = {{\n"));
    out.push_str("        type = \"disk\";\n");
    out.push_str(&format!("        device = \"{}\";\n", disk.path));
    out.push_str("        content = {\n");
    out.push_str("          type = \"gpt\";\n");
    out.push_str("          partitions = {\n");
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
    out.push_str("            lvm = {\n");
    out.push_str("              size = \"100%\";\n");
    out.push_str("              content = {\n");
    out.push_str("                type = \"lvm_pv\";\n");
    out.push_str("                vg = \"pool\";\n");
    out.push_str("              };\n");
    out.push_str("            };\n");
    out.push_str("          };\n");
    out.push_str("        };\n");
    out.push_str("      };\n");
    out.push_str("    };\n");
    out.push_str("    lvm_vg = {\n");
    out.push_str("      pool = {\n");
    out.push_str("        type = \"lvm_vg\";\n");
    out.push_str("        lvs = {\n");
    for volume in &state.volumes {
        render_volume(&mut out, volume)?;
    }
    out.push_str("        };\n");
    out.push_str("      };\n");
    out.push_str("    };\n");
    out.push_str("  };\n");
    out.push_str("}\n");
    Ok(out)
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

fn render_volume(out: &mut String, volume: &Volume) -> Result<()> {
    validate_attr(&volume.name)?;
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

fn validate(state: &InstallState) -> Result<()> {
    if state.disks.is_empty() {
        return Err("at least one disk is required".to_string());
    }
    if state.volumes.is_empty() {
        return Err("at least one volume is required".to_string());
    }
    if state.used_gib() > state.total_disk_gib() {
        return Err(format!(
            "volume layout uses {}G but selected disks only provide {}G",
            state.used_gib(),
            state.total_disk_gib()
        ));
    }
    for disk in &state.disks {
        validate_disk_path(&disk.path)?;
    }
    for volume in &state.volumes {
        validate_attr(&volume.name)?;
    }
    Ok(())
}

fn disk_key(path: &str) -> Result<String> {
    validate_disk_path(path)?;
    let name = path
        .rsplit('/')
        .next()
        .ok_or_else(|| format!("invalid disk path: {path}"))?;
    let key = name
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect::<String>();
    validate_attr(&key)?;
    Ok(key)
}

fn validate_disk_path(path: &str) -> Result<()> {
    if path.starts_with("/dev/")
        && path
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'-' | b'_'))
    {
        Ok(())
    } else {
        Err(format!("disk path is not supported: {path}"))
    }
}

fn validate_attr(value: &str) -> Result<()> {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return Err("empty Nix attr name".to_string());
    };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return Err(format!("invalid Nix attr name: {value}"));
    }
    if chars.all(|ch| ch.is_ascii_alphanumeric() || ch == '_') {
        Ok(())
    } else {
        Err(format!("invalid Nix attr name: {value}"))
    }
}

#[cfg(test)]
mod tests {
    use super::render;
    use crate::install_state::InstallState;

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
    fn rejects_over_capacity_layout() {
        let mut state = InstallState::sample();
        state.disks[0].size_gib = 100;
        let err = render(&state).unwrap_err();
        assert!(err.contains("volume layout uses"));
    }
}
