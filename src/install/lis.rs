//! LIS (Linux Installation Specification) producer/consumer for nox.
//!
//! `from_state` maps the wizard's `InstallState` onto a LIS v0.1 document —
//! the distro-neutral core sections plus an `x-nixos` extension carrying what
//! only this applier understands. `apply_to_state` is the inverse: it powers
//! both resume-previous-answers and the `lis-apply` CLI (LIS → generated nix).
//! Spec: https://github.com/onix-os/lis

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::install::state::{
    DiskSlice, InstallRole, InstallState, Mountpoint, SecretsMode, Subvolume, UserAccount,
    Volume, VolumeFs, VolumeGroupDraft,
};
use crate::Result;

pub const LIS_VERSION: &str = "0.1.0";

// ── document model (the subset nox produces/consumes) ────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LisDocument {
    pub lis: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meta: Option<Meta>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<Target>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub storage: Option<Storage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub boot: Option<Boot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system: Option<System>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub users: Vec<User>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network: Option<Network>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub software: Option<Software>,
    #[serde(rename = "x-nixos", default, skip_serializing_if = "Option::is_none")]
    pub x_nixos: Option<XNixos>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Meta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generator: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Target {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub firmware: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub disks: Vec<TargetDisk>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TargetDisk {
    pub id: String,
    pub r#match: DiskMatch,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DiskMatch {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Storage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wipe: Option<bool>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub partitions: Vec<Partition>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub lvm: Vec<LvmGroup>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Partition {
    pub disk: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fs: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LvmGroup {
    pub name: String,
    pub devices: Vec<String>,
    pub volumes: Vec<LvmVolume>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LvmVolume {
    pub name: String,
    pub size: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fs: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mountpoint: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub subvolumes: Vec<LisSubvolume>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LisSubvolume {
    pub name: String,
    pub mountpoint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Boot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loader: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct System {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hostname: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timezone: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct User {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub admin: Option<bool>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub groups: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password: Option<Password>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dotfiles: Option<Dotfiles>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Password {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub locked: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Dotfiles {
    pub repo: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Network {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<Ssh>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Ssh {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Software {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
}

/// What only the NixOS applier (this repo's flake) understands.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct XNixos {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secrets: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secrets_key_file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network_cleanup: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bin_ensure: Option<bool>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub data_mounts: BTreeMap<String, String>,
}

// ── InstallState → LIS ───────────────────────────────────────────

fn disk_handle(path: &str) -> String {
    path.trim_start_matches("/dev/").replace('/', "-")
}

fn fs_name(fs: VolumeFs) -> &'static str {
    match fs {
        VolumeFs::Btrfs => "btrfs",
        VolumeFs::Ext4 => "ext4",
        VolumeFs::Xfs => "xfs",
        VolumeFs::Swap => "swap",
    }
}

fn fs_from_name(name: &str) -> VolumeFs {
    match name {
        "ext4" => VolumeFs::Ext4,
        "xfs" => VolumeFs::Xfs,
        "swap" => VolumeFs::Swap,
        _ => VolumeFs::Btrfs,
    }
}

pub fn from_state(state: &InstallState) -> LisDocument {
    // Disk handles + partitions: the ESP on the first managed disk, then one
    // raw partition per pool slice (the LVM PVs).
    let managed: Vec<&String> = state
        .disk_slices
        .iter()
        .filter(|(_, slices)| !slices.is_empty())
        .map(|(path, _)| path)
        .collect();
    let mut disks = Vec::new();
    let mut partitions = Vec::new();
    let mut slice_ids: BTreeMap<(String, usize), String> = BTreeMap::new();
    for (di, path) in managed.iter().enumerate() {
        let handle = disk_handle(path);
        disks.push(TargetDisk {
            id: handle.clone(),
            r#match: DiskMatch { path: Some((*path).clone()) },
        });
        if di == 0 {
            partitions.push(Partition {
                disk: handle.clone(),
                id: None,
                role: Some("esp".to_string()),
                size: Some(format!("{}MiB", state.esp_size_mib)),
                fs: None,
            });
        }
        for (i, slice) in state.slices_for_disk(path).iter().enumerate() {
            let id = format!("p-{handle}-{i}");
            slice_ids.insert(((*path).clone(), i), id.clone());
            partitions.push(Partition {
                disk: handle.clone(),
                id: Some(id),
                role: Some("raw".to_string()),
                size: Some(format!("{}GiB", slice.size_gib)),
                fs: Some("none".to_string()),
            });
        }
    }

    // Pools → LVM groups; volumes keep their pool assignment.
    let mut lvm = Vec::new();
    for group in &state.volume_groups {
        let mut devices = Vec::new();
        for path in &managed {
            for (i, slice) in state.slices_for_disk(path).iter().enumerate() {
                if slice.pool == group.name {
                    devices.push(slice_ids[&((*path).clone(), i)].clone());
                }
            }
        }
        if devices.is_empty() {
            continue;
        }
        let volumes = state
            .volumes
            .iter()
            .filter(|v| state.volume_group_for_volume(&v.name) == group.name)
            .map(|v| LvmVolume {
                name: v.name.clone(),
                size: if v.fill {
                    "rest".to_string()
                } else {
                    format!("{}GiB", v.size_gib)
                },
                fs: Some(fs_name(v.fs).to_string()),
                mountpoint: match &v.mountpoint {
                    Mountpoint::Path(p) => Some(p.clone()),
                    Mountpoint::Swap => None,
                },
                subvolumes: v
                    .subvolumes
                    .iter()
                    .map(|s| LisSubvolume {
                        name: s.name.clone(),
                        mountpoint: s.mountpoint.clone(),
                    })
                    .collect(),
            })
            .collect();
        lvm.push(LvmGroup {
            name: group.name.clone(),
            devices,
            volumes,
        });
    }

    let users = state
        .users
        .iter()
        .map(|u| User {
            name: u.name.clone(),
            admin: Some(u.groups.iter().any(|g| g == "wheel")),
            groups: u.groups.clone(),
            password: u.password_hash.as_ref().map(|h| Password {
                hash: Some(h.clone()),
                locked: None,
            }),
            dotfiles: u.dotfiles.as_ref().map(|r| Dotfiles { repo: r.clone() }),
        })
        .collect();

    LisDocument {
        lis: LIS_VERSION.to_string(),
        meta: Some(Meta {
            name: Some(state.hostname.clone()),
            generator: Some(format!("nox {}", env!("CARGO_PKG_VERSION"))),
            description: None,
        }),
        target: Some(Target {
            arch: Some("x86_64".to_string()),
            firmware: Some("uefi".to_string()),
            disks,
        }),
        storage: Some(Storage {
            wipe: Some(state.overwrite_existing_storage),
            partitions,
            lvm,
        }),
        boot: Some(Boot { loader: Some("systemd-boot".to_string()) }),
        system: Some(System {
            hostname: Some(state.hostname.clone()),
            timezone: Some(state.timezone.clone()),
        }),
        users,
        network: Some(Network {
            ssh: Some(Ssh { enabled: Some(state.allow_ssh) }),
        }),
        software: Some(Software {
            role: Some(match state.role {
                InstallRole::Server => "server".to_string(),
                InstallRole::Laptop => "minimal".to_string(),
            }),
        }),
        x_nixos: Some(XNixos {
            role: Some(match state.role {
                InstallRole::Server => "server".to_string(),
                InstallRole::Laptop => "laptop".to_string(),
            }),
            secrets: Some(state.secrets_mode != SecretsMode::Skip),
            secrets_key_file: match &state.secrets_mode {
                SecretsMode::KeyFile(path) => Some(path.clone()),
                _ => None,
            },
            remote: Some(state.remote.clone()),
            network_cleanup: Some(state.network_route_cleanup),
            bin_ensure: Some(!state.skip_bin_ensure),
            data_mounts: state.data_mounts.clone(),
        }),
    }
}

// ── LIS → InstallState ───────────────────────────────────────────

fn parse_gib(size: &str) -> Option<u64> {
    if let Some(n) = size.strip_suffix("GiB") {
        return n.parse().ok();
    }
    if let Some(n) = size.strip_suffix("MiB") {
        return n.parse::<u64>().ok().map(|m| m.div_ceil(1024));
    }
    if let Some(n) = size.strip_suffix("TiB") {
        return n.parse::<u64>().ok().map(|t| t * 1024);
    }
    None
}

/// Fold a LIS document back into an `InstallState` (over `draft()` defaults).
/// Unknown/foreign sections are ignored — this consumes the nox subset.
pub fn apply_to_state(doc: &LisDocument, state: &mut InstallState) {
    if let Some(system) = &doc.system {
        if let Some(h) = &system.hostname {
            state.hostname = h.clone();
        }
        if let Some(tz) = &system.timezone {
            state.timezone = tz.clone();
        }
    }
    if let Some(network) = &doc.network {
        if let Some(ssh) = &network.ssh {
            if let Some(on) = ssh.enabled {
                state.allow_ssh = on;
            }
        }
    }
    if !doc.users.is_empty() {
        state.users = doc
            .users
            .iter()
            .map(|u| {
                let mut groups = u.groups.clone();
                if u.admin == Some(true) && !groups.iter().any(|g| g == "wheel") {
                    groups.insert(0, "wheel".to_string());
                }
                UserAccount {
                    name: u.name.clone(),
                    password_hash: u.password.as_ref().and_then(|p| p.hash.clone()),
                    dotfiles: u.dotfiles.as_ref().map(|d| d.repo.clone()),
                    groups,
                }
            })
            .collect();
        state.sync_primary_user();
    }
    if let Some(x) = &doc.x_nixos {
        if let Some(role) = &x.role {
            state.role = if role == "server" {
                InstallRole::Server
            } else {
                InstallRole::Laptop
            };
        }
        if let Some(remote) = &x.remote {
            state.remote = remote.clone();
        }
        if let Some(on) = x.network_cleanup {
            state.network_route_cleanup = on;
        }
        if let Some(on) = x.bin_ensure {
            state.skip_bin_ensure = !on;
        }
        state.secrets_mode = match (&x.secrets, &x.secrets_key_file) {
            (Some(false), _) => SecretsMode::Skip,
            (_, Some(path)) => SecretsMode::KeyFile(path.clone()),
            _ => SecretsMode::YubiKey,
        };
        state.data_mounts = x.data_mounts.clone();
    }

    let Some(storage) = &doc.storage else { return };
    if let Some(wipe) = storage.wipe {
        state.overwrite_existing_storage = wipe;
    }

    // Disk handle → device path from the target section.
    let mut handle_paths: BTreeMap<&str, &str> = BTreeMap::new();
    if let Some(target) = &doc.target {
        for disk in &target.disks {
            if let Some(path) = &disk.r#match.path {
                handle_paths.insert(disk.id.as_str(), path.as_str());
            }
        }
    }
    // Partition id → (device path, size); the ESP restores its size.
    let mut part_info: BTreeMap<&str, (&str, u64)> = BTreeMap::new();
    for part in &storage.partitions {
        if part.role.as_deref() == Some("esp") {
            if let Some(size) = &part.size {
                if let Some(mib) = size
                    .strip_suffix("MiB")
                    .and_then(|n| n.parse::<u64>().ok())
                    .or_else(|| parse_gib(size).map(|g| g * 1024))
                {
                    state.esp_size_mib = mib;
                }
            }
            continue;
        }
        let (Some(id), Some(path)) = (&part.id, handle_paths.get(part.disk.as_str())) else {
            continue;
        };
        let gib = part.size.as_deref().and_then(parse_gib).unwrap_or(0);
        part_info.insert(id.as_str(), (path, gib));
    }

    if storage.lvm.is_empty() {
        return;
    }
    // Pools are LVM volume groups; multi-disk documents join disks into them.
    state.use_lvm = true;
    state.storage_mode = crate::install::state::StorageMode::JoinedLvm;
    state.volume_groups = storage
        .lvm
        .iter()
        .map(|g| VolumeGroupDraft { name: g.name.clone() })
        .collect();
    let mut disk_slices: BTreeMap<String, Vec<DiskSlice>> = BTreeMap::new();
    let mut volumes = Vec::new();
    let mut assignments = BTreeMap::new();
    for group in &storage.lvm {
        for dev in &group.devices {
            if let Some((path, gib)) = part_info.get(dev.as_str()) {
                disk_slices
                    .entry((*path).to_string())
                    .or_default()
                    .push(DiskSlice { pool: group.name.clone(), size_gib: *gib });
            }
        }
        for vol in &group.volumes {
            let fill = vol.size == "rest";
            volumes.push(Volume {
                name: vol.name.clone(),
                mountpoint: match (&vol.mountpoint, vol.fs.as_deref()) {
                    (_, Some("swap")) => Mountpoint::Swap,
                    (Some(p), _) => Mountpoint::Path(p.clone()),
                    (None, _) => Mountpoint::Swap,
                },
                size_gib: if fill {
                    1
                } else {
                    parse_gib(&vol.size).unwrap_or(1).max(1)
                },
                fs: vol.fs.as_deref().map(fs_from_name).unwrap_or(VolumeFs::Btrfs),
                subvolumes: vol
                    .subvolumes
                    .iter()
                    .map(|s| Subvolume {
                        // nox names subvolumes without the btrfs "@" prefix
                        // (disko adds it); accept either spelling.
                        name: s.name.trim_start_matches('@').to_string(),
                        mountpoint: s.mountpoint.clone(),
                    })
                    .collect(),
                fill,
            });
            assignments.insert(vol.name.clone(), group.name.clone());
        }
    }
    state.disk_slices = disk_slices;
    state.volumes = volumes;
    state.volume_volume_groups = assignments;
    // Synthetic capacities: slices plus the ESP reservation. Real device
    // sizes take over as soon as discovery runs on an actual target.
    let esp_gib = state.esp_size_mib.div_ceil(1024);
    state.disks = state
        .disk_slices
        .keys()
        .map(|path| crate::install::state::DiskChoice {
            path: path.clone(),
            size_gib: state
                .slices_for_disk(path)
                .iter()
                .map(|s| s.size_gib)
                .sum::<u64>()
                + esp_gib,
            model: None,
        })
        .collect();
}

// ── file IO ──────────────────────────────────────────────────────

pub fn document_path(repo: &Path) -> std::path::PathBuf {
    repo.join("host/generated/system.lis.json")
}

pub fn write(repo: &Path, state: &InstallState) -> Result<()> {
    let doc = from_state(state);
    let json = serde_json::to_string_pretty(&doc)
        .map_err(|err| format!("failed to serialize LIS document: {err}"))?;
    let path = document_path(repo);
    std::fs::write(&path, json + "\n")
        .map_err(|err| format!("failed to write {}: {err}", path.display()))
}

pub fn read(path: &Path) -> Result<LisDocument> {
    let text = std::fs::read_to_string(path)
        .map_err(|err| format!("failed to read {}: {err}", path.display()))?;
    let doc: LisDocument = serde_json::from_str(&text)
        .map_err(|err| format!("{} is not a valid LIS document: {err}", path.display()))?;
    if !doc.lis.starts_with("0.1.") {
        return Err(format!(
            "{}: unsupported LIS version {} (this applier accepts 0.1.x)",
            path.display(),
            doc.lis
        ));
    }
    Ok(doc)
}

/// A fresh draft state with the document's answers folded in.
pub fn state_from(doc: &LisDocument) -> InstallState {
    let mut state = InstallState::draft();
    apply_to_state(doc, &mut state);
    state
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state_with_layout() -> InstallState {
        let mut state = InstallState::sample();
        state.hostname = "tron".to_string();
        state.role = InstallRole::Server;
        state.secrets_mode = SecretsMode::Skip;
        state.overwrite_existing_storage = true;
        state.disk_slices = BTreeMap::from([
            (
                "/dev/sda".to_string(),
                vec![DiskSlice { pool: "pool".to_string(), size_gib: 400 }],
            ),
            (
                "/dev/sdb".to_string(),
                vec![DiskSlice { pool: "pool".to_string(), size_gib: 900 }],
            ),
        ]);
        state.volumes = vec![
            Volume {
                name: "root".to_string(),
                mountpoint: Mountpoint::Path("/".to_string()),
                size_gib: 100,
                fs: VolumeFs::Btrfs,
                subvolumes: vec![Subvolume {
                    name: "@home".to_string(),
                    mountpoint: "/home".to_string(),
                }],
                fill: false,
            },
            Volume {
                name: "swap".to_string(),
                mountpoint: Mountpoint::Swap,
                size_gib: 8,
                fs: VolumeFs::Swap,
                subvolumes: vec![],
                fill: false,
            },
            Volume {
                name: "data".to_string(),
                mountpoint: Mountpoint::Path("/data".to_string()),
                size_gib: 1,
                fs: VolumeFs::Xfs,
                subvolumes: vec![],
                fill: true,
            },
        ];
        state.volume_volume_groups = state
            .volumes
            .iter()
            .map(|v| (v.name.clone(), "pool".to_string()))
            .collect();
        state.users[0].password_hash = Some("$6$salt$hash".to_string());
        state
    }

    #[test]
    fn emits_core_sections_and_x_nixos() {
        let doc = from_state(&state_with_layout());
        assert_eq!(doc.lis, LIS_VERSION);
        let storage = doc.storage.as_ref().unwrap();
        // ESP + one PV partition per slice.
        assert_eq!(storage.partitions.len(), 3);
        assert_eq!(storage.partitions[0].role.as_deref(), Some("esp"));
        assert_eq!(storage.lvm.len(), 1);
        assert_eq!(storage.lvm[0].devices.len(), 2);
        assert_eq!(storage.lvm[0].volumes.len(), 3);
        // fill → "rest", swap loses its mountpoint but keeps fs swap.
        let data = storage.lvm[0].volumes.iter().find(|v| v.name == "data").unwrap();
        assert_eq!(data.size, "rest");
        let swap = storage.lvm[0].volumes.iter().find(|v| v.name == "swap").unwrap();
        assert_eq!(swap.fs.as_deref(), Some("swap"));
        assert!(swap.mountpoint.is_none());
        let x = doc.x_nixos.as_ref().unwrap();
        assert_eq!(x.secrets, Some(false));
        assert_eq!(x.role.as_deref(), Some("server"));
    }

    #[test]
    fn roundtrips_through_json_back_into_state() {
        let original = state_with_layout();
        let json = serde_json::to_string(&from_state(&original)).unwrap();
        let doc: LisDocument = serde_json::from_str(&json).unwrap();
        let restored = state_from(&doc);

        assert_eq!(restored.hostname, "tron");
        assert_eq!(restored.role, InstallRole::Server);
        assert_eq!(restored.secrets_mode, SecretsMode::Skip);
        assert!(restored.overwrite_existing_storage);
        assert_eq!(restored.esp_size_mib, original.esp_size_mib);
        assert_eq!(restored.disk_slices.len(), 2);
        assert_eq!(restored.slices_for_disk("/dev/sdb")[0].size_gib, 900);
        assert_eq!(restored.volumes.len(), 3);
        let root = restored.volumes.iter().find(|v| v.name == "root").unwrap();
        assert_eq!(root.mountpoint, Mountpoint::Path("/".to_string()));
        assert_eq!(root.subvolumes.len(), 1);
        let data = restored.volumes.iter().find(|v| v.name == "data").unwrap();
        assert!(data.fill);
        assert_eq!(restored.volume_group_for_volume("root"), "pool");
        assert_eq!(
            restored.users[0].password_hash.as_deref(),
            Some("$6$salt$hash")
        );
        assert!(restored.users[0].groups.iter().any(|g| g == "wheel"));
    }

    #[test]
    fn rejects_future_major_versions() {
        let dir = std::env::temp_dir().join("lis-version-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("doc.lis.json");
        std::fs::write(&path, r#"{ "lis": "2.0.0" }"#).unwrap();
        assert!(read(&path).unwrap_err().contains("unsupported LIS version"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
