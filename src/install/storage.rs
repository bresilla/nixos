use std::collections::{BTreeMap, HashSet};

use crate::install::state::{
    DiskRole, Filesystem, InstallState, StorageMode, Volume, DEFAULT_STORAGE_POOL_NAME,
};
use crate::Result;

#[allow(dead_code)]
pub const DEFAULT_LVM_VG_NAME: &str = DEFAULT_STORAGE_POOL_NAME;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageLayout {
    pub mode: StorageMode,
    pub filesystem: Filesystem,
    pub encrypt: bool,
    pub doc_subvolumes: Vec<String>,
    pub disks: Vec<StorageDisk>,
    pub volume_groups: Vec<StorageVolumeGroup>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageDisk {
    pub key: String,
    pub path: String,
    pub size_gib: u64,
    pub role: DiskRole,
    pub create_esp: bool,
    /// EFI System Partition size in MiB (only meaningful when create_esp).
    pub esp_size_mib: u64,
    pub lvm_vg: String,
}

pub use crate::install::state::DiskRole as StorageDiskRole;

#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(dead_code)]
pub enum StorageAction {
    WipeDisk { path: String },
    CreateEsp { path: String },
    JoinVolumeGroup { path: String, vg_name: String },
    FormatLogicalVolume { vg_name: String, lv_name: String },
    LeaveExisting { path: String },
    Ignore { path: String },
}

impl StorageAction {
    pub fn label(&self) -> String {
        match self {
            StorageAction::WipeDisk { path } => format!("wipe disk {path}"),
            StorageAction::CreateEsp { path } => format!("create ESP on {path}"),
            StorageAction::JoinVolumeGroup { path, vg_name } => {
                format!("join {path} to VG {vg_name}")
            }
            StorageAction::FormatLogicalVolume { vg_name, lv_name } => {
                format!("format LV {vg_name}/{lv_name}")
            }
            StorageAction::LeaveExisting { path } => format!("leave existing {path}"),
            StorageAction::Ignore { path } => format!("ignore {path}"),
        }
    }

    pub fn destructive(&self) -> bool {
        matches!(
            self,
            StorageAction::WipeDisk { .. }
                | StorageAction::CreateEsp { .. }
                | StorageAction::JoinVolumeGroup { .. }
                | StorageAction::FormatLogicalVolume { .. }
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageVolumeGroup {
    pub name: String,
    pub logical_volumes: Vec<Volume>,
}

impl StorageLayout {
    pub fn from_state(state: &InstallState) -> Result<Self> {
        match state.storage_mode {
            StorageMode::SingleDisk | StorageMode::JoinedLvm => Self::single_pool_from_state(state),
            StorageMode::SeparatePools => Self::separate_pools_from_state(state),
            StorageMode::Manual => Err("manual storage mode is not implemented yet".to_string()),
        }
    }

    /// Assemble the rendered layout from the draft state without applying
    /// mode-specific validation. Disk-to-VG and volume-to-VG assignments come
    /// straight from `InstallState`, so this already handles arbitrary
    /// single-pool and multi-pool topologies; callers validate for their mode.
    fn assemble(state: &InstallState) -> Result<Self> {
        if state.disks.is_empty() {
            return Err("at least one disk is required".to_string());
        }
        if state.volumes.is_empty() {
            return Err("at least one volume is required".to_string());
        }

        let visible_disks = state.visible_disks();
        let mut keys = HashSet::new();
        let disks = visible_disks
            .iter()
            .map(|disk| {
                validate_disk_path(&disk.path)?;
                let key = disk_key(&disk.path)?;
                if !keys.insert(key.clone()) {
                    return Err(format!("duplicate rendered disk key: {key}"));
                }
                let role = state.disk_role_for_path(&disk.path);
                Ok(StorageDisk {
                    key,
                    path: disk.path.clone(),
                    size_gib: disk.size_gib,
                    role,
                    create_esp: role == DiskRole::System,
                    esp_size_mib: state.esp_size_mib.max(256),
                    lvm_vg: state
                        .disk_volume_group_for_path(&disk.path)
                        .unwrap_or_else(|| state.default_volume_group_name())
                        .to_string(),
                })
            })
            .collect::<Result<Vec<_>>>()?;

        let volume_groups = state
            .volume_groups
            .iter()
            .map(|group| StorageVolumeGroup {
                name: group.name.clone(),
                logical_volumes: state
                    .volumes
                    .iter()
                    .filter(|volume| state.volume_group_for_volume(&volume.name) == group.name)
                    .cloned()
                    .collect(),
            })
            .filter(|group| !group.logical_volumes.is_empty())
            .collect::<Vec<_>>();

        Ok(Self {
            mode: state.storage_mode,
            filesystem: state.filesystem,
            encrypt: state.encrypt,
            doc_subvolumes: state.doc_subvolumes.clone(),
            disks,
            volume_groups,
        })
    }

    pub fn single_pool_from_state(state: &InstallState) -> Result<Self> {
        let layout = Self::assemble(state)?;
        layout.validate()?;
        Ok(layout)
    }

    /// Build a separate-pools layout: every install disk lives in its own volume
    /// group. Disk/volume group assignments come from the draft state; validation
    /// enforces the one-disk-per-group rule that distinguishes this from joined-lvm.
    pub fn separate_pools_from_state(state: &InstallState) -> Result<Self> {
        let layout = Self::assemble(state)?;
        layout.validate()?;
        Ok(layout)
    }

    pub fn total_disk_gib(&self) -> u64 {
        self.disks
            .iter()
            .filter(|disk| matches!(disk.role, DiskRole::System | DiskRole::PoolMember))
            .map(|disk| disk.size_gib)
            .sum()
    }

    pub fn used_gib(&self) -> u64 {
        self.volume_groups
            .iter()
            .flat_map(|vg| vg.logical_volumes.iter())
            .map(|volume| volume.size_gib)
            .sum()
    }

    pub fn lvm_vg_names(&self) -> Vec<String> {
        self.volume_groups
            .iter()
            .map(|vg| vg.name.clone())
            .collect()
    }

    #[allow(dead_code)]
    pub fn actions(&self) -> Vec<StorageAction> {
        let mut actions = Vec::new();
        for disk in &self.disks {
            match disk.role {
                DiskRole::System | DiskRole::PoolMember => {
                    actions.push(StorageAction::WipeDisk {
                        path: disk.path.clone(),
                    });
                    if disk.create_esp {
                        actions.push(StorageAction::CreateEsp {
                            path: disk.path.clone(),
                        });
                    }
                    actions.push(StorageAction::JoinVolumeGroup {
                        path: disk.path.clone(),
                        vg_name: disk.lvm_vg.clone(),
                    });
                }
                DiskRole::Data | DiskRole::Reserve => {
                    actions.push(StorageAction::LeaveExisting {
                        path: disk.path.clone(),
                    });
                }
                DiskRole::Ignore => {
                    actions.push(StorageAction::Ignore {
                        path: disk.path.clone(),
                    });
                }
            }
        }
        for volume_group in &self.volume_groups {
            for volume in &volume_group.logical_volumes {
                actions.push(StorageAction::FormatLogicalVolume {
                    vg_name: volume_group.name.clone(),
                    lv_name: volume.name.clone(),
                });
            }
        }
        actions
    }

    pub fn validate(&self) -> Result<()> {
        if self.disks.is_empty() {
            return Err("at least one disk is required".to_string());
        }
        if self.volume_groups.is_empty() {
            return Err("at least one volume group is required".to_string());
        }
        if self.mode == StorageMode::SingleDisk
            && self
                .disks
                .iter()
                .filter(|disk| matches!(disk.role, DiskRole::System | DiskRole::PoolMember))
                .count()
                != 1
        {
            return Err("single-disk storage mode requires exactly one install disk".to_string());
        }
        if self.mode == StorageMode::Manual {
            return Err("manual storage mode is not implemented yet".to_string());
        }
        if self.mode == StorageMode::SeparatePools {
            let mut group_disk_counts = BTreeMap::<&str, usize>::new();
            for disk in self
                .disks
                .iter()
                .filter(|disk| matches!(disk.role, DiskRole::System | DiskRole::PoolMember))
            {
                *group_disk_counts.entry(disk.lvm_vg.as_str()).or_default() += 1;
            }
            if let Some((group, _)) = group_disk_counts.iter().find(|(_, count)| **count > 1) {
                return Err(format!(
                    "separate-pools storage mode requires one install disk per volume group, but {group} has more than one"
                ));
            }
        }
        if self.filesystem == Filesystem::Btrfs {
            for subvol in &self.doc_subvolumes {
                validate_subvolume_name(subvol)?;
            }
        }
        if !self.disks.iter().any(|disk| disk.create_esp) {
            return Err("at least one disk must create an ESP".to_string());
        }
        if self
            .disks
            .iter()
            .any(|disk| disk.create_esp && disk.role != DiskRole::System)
        {
            return Err("only system disks can create an ESP".to_string());
        }
        for disk in &self.disks {
            validate_attr(&disk.key)?;
            validate_disk_path(&disk.path)?;
            validate_attr(&disk.lvm_vg)?;
        }
        let volume_group_names = self
            .volume_groups
            .iter()
            .map(|vg| vg.name.as_str())
            .collect::<HashSet<_>>();
        for disk in self
            .disks
            .iter()
            .filter(|disk| matches!(disk.role, DiskRole::System | DiskRole::PoolMember))
        {
            if !volume_group_names.contains(disk.lvm_vg.as_str()) {
                return Err(format!(
                    "install disk {} is assigned to volume group {} but that group has no logical volumes",
                    disk.path, disk.lvm_vg
                ));
            }
        }
        for vg in &self.volume_groups {
            validate_attr(&vg.name)?;
            if vg.logical_volumes.is_empty() {
                return Err(format!("volume group has no logical volumes: {}", vg.name));
            }
            for volume in &vg.logical_volumes {
                validate_attr(&volume.name)?;
            }
        }
        let mut volume_group_capacity = BTreeMap::<String, u64>::new();
        for disk in self
            .disks
            .iter()
            .filter(|disk| matches!(disk.role, DiskRole::System | DiskRole::PoolMember))
        {
            *volume_group_capacity
                .entry(disk.lvm_vg.clone())
                .or_default() += disk.size_gib;
        }
        for vg in &self.volume_groups {
            let total = *volume_group_capacity.get(&vg.name).unwrap_or(&0);
            let used = vg
                .logical_volumes
                .iter()
                .map(|volume| volume.size_gib)
                .sum::<u64>();
            if total == 0 {
                return Err(format!(
                    "volume group {} has logical volumes but no assigned install disks",
                    vg.name
                ));
            }
            if used > total {
                return Err(format!(
                    "volume group {} uses {}G but assigned disks only provide {}G",
                    vg.name, used, total
                ));
            }
        }
        if self.used_gib() > self.total_disk_gib() {
            return Err(format!(
                "volume layout uses {}G but selected disks only provide {}G",
                self.used_gib(),
                self.total_disk_gib()
            ));
        }
        Ok(())
    }
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

pub fn validate_disk_path(path: &str) -> Result<()> {
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

fn validate_subvolume_name(value: &str) -> Result<()> {
    if value.is_empty() {
        return Err("btrfs subvolume name cannot be empty".to_string());
    }
    if value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        Ok(())
    } else {
        Err(format!("invalid btrfs subvolume name: {value}"))
    }
}

pub fn validate_attr(value: &str) -> Result<()> {
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
    use super::{
        StorageAction, StorageDisk, StorageDiskRole, StorageLayout, StorageVolumeGroup,
        DEFAULT_LVM_VG_NAME,
    };
    use crate::install::state::{DiskChoice, DiskRole, InstallState, StorageMode};

    #[test]
    fn builds_single_pool_layout_from_current_install_state() {
        let layout = StorageLayout::single_pool_from_state(&InstallState::sample()).unwrap();

        assert_eq!(layout.disks.len(), 1);
        assert_eq!(layout.disks[0].key, "nvme0n1");
        assert_eq!(layout.disks[0].role, StorageDiskRole::System);
        assert!(layout.disks[0].create_esp);
        assert_eq!(layout.disks[0].lvm_vg, DEFAULT_LVM_VG_NAME);
        assert_eq!(layout.volume_groups[0].name, DEFAULT_LVM_VG_NAME);
        assert_eq!(layout.volume_groups[0].logical_volumes.len(), 6);
    }

    #[test]
    fn joins_multiple_selected_disks_into_one_pool() {
        let mut state = InstallState::sample();
        let second_disk = DiskChoice {
            path: "/dev/nvme1n1".to_string(),
            size_gib: 465,
            model: None,
        };
        state.discovered_disks.push(second_disk.clone());
        state.disks.push(second_disk.clone());
        state
            .disk_roles
            .insert(second_disk.path.clone(), DiskRole::PoolMember);
        state.normalize_disk_roles();

        let layout = StorageLayout::single_pool_from_state(&state).unwrap();

        assert_eq!(layout.disks.len(), 2);
        assert_eq!(layout.disks[0].role, StorageDiskRole::System);
        assert_eq!(layout.disks[1].role, StorageDiskRole::PoolMember);
        assert!(layout.disks[0].create_esp);
        assert!(!layout.disks[1].create_esp);
        assert_eq!(layout.lvm_vg_names(), vec![DEFAULT_LVM_VG_NAME.to_string()]);
    }

    #[test]
    fn uses_user_volume_group_assignments() {
        let mut state = InstallState::sample();
        let second_disk = DiskChoice {
            path: "/dev/nvme1n1".to_string(),
            size_gib: 465,
            model: None,
        };
        state.discovered_disks.push(second_disk.clone());
        state.set_disk_role(&second_disk.path, DiskRole::PoolMember);
        state.set_disk_volume_group(&second_disk.path, "extra");
        state.set_volume_group_for_volume("pkg", "extra");

        let layout = StorageLayout::from_state(&state).unwrap();

        assert_eq!(layout.disks[0].lvm_vg, "pool");
        assert_eq!(layout.disks[1].lvm_vg, "extra");
        assert_eq!(
            layout.lvm_vg_names(),
            vec!["pool".to_string(), "extra".to_string()]
        );
        assert_eq!(
            layout.volume_groups[1]
                .logical_volumes
                .iter()
                .map(|volume| volume.name.as_str())
                .collect::<Vec<_>>(),
            vec!["pkg"]
        );
    }

    #[test]
    fn rejects_per_volume_group_over_capacity_layout() {
        let mut state = InstallState::sample();
        let second_disk = DiskChoice {
            path: "/dev/nvme1n1".to_string(),
            size_gib: 16,
            model: None,
        };
        state.discovered_disks.push(second_disk.clone());
        state.set_disk_role(&second_disk.path, DiskRole::PoolMember);
        state.set_disk_volume_group(&second_disk.path, "tiny");
        state.set_volume_group_for_volume("pkg", "tiny");

        let err = StorageLayout::from_state(&state).unwrap_err();

        assert!(err.contains("volume group tiny uses 32G but assigned disks only provide 16G"));
    }

    #[test]
    fn single_disk_mode_accepts_one_install_disk() {
        let mut state = InstallState::sample();
        state.storage_mode = StorageMode::SingleDisk;

        let layout = StorageLayout::from_state(&state).unwrap();

        assert_eq!(layout.mode, StorageMode::SingleDisk);
        assert_eq!(layout.disks.len(), 1);
        assert_eq!(layout.lvm_vg_names(), vec![DEFAULT_LVM_VG_NAME.to_string()]);
    }

    #[test]
    fn single_disk_mode_rejects_multiple_install_disks() {
        let mut state = InstallState::sample();
        state.storage_mode = StorageMode::SingleDisk;
        let second_disk = DiskChoice {
            path: "/dev/nvme1n1".to_string(),
            size_gib: 465,
            model: None,
        };
        state.discovered_disks.push(second_disk.clone());
        state.disks.push(second_disk.clone());
        state
            .disk_roles
            .insert(second_disk.path.clone(), DiskRole::PoolMember);
        state.normalize_disk_roles();

        let err = StorageLayout::from_state(&state).unwrap_err();

        assert!(err.contains("single-disk storage mode requires exactly one install disk"));
    }

    #[test]
    fn manual_storage_mode_fails_before_rendering_wrong_disko() {
        let mut state = InstallState::sample();
        state.storage_mode = StorageMode::Manual;

        let err = StorageLayout::from_state(&state).unwrap_err();

        assert!(err.contains("manual storage mode is not implemented yet"));
    }

    #[test]
    fn separate_pools_gives_each_disk_its_own_volume_group() {
        let mut state = InstallState::sample();
        state.storage_mode = StorageMode::SeparatePools;
        let second_disk = DiskChoice {
            path: "/dev/nvme1n1".to_string(),
            size_gib: 465,
            model: None,
        };
        state.discovered_disks.push(second_disk.clone());
        state.set_disk_role(&second_disk.path, DiskRole::PoolMember);
        state.set_disk_volume_group(&second_disk.path, "extra");
        state.set_volume_group_for_volume("pkg", "extra");

        let layout = StorageLayout::from_state(&state).unwrap();

        assert_eq!(layout.mode, StorageMode::SeparatePools);
        assert_eq!(layout.lvm_vg_names(), vec!["pool".to_string(), "extra".to_string()]);
    }

    #[test]
    fn separate_pools_rejects_two_disks_in_one_group() {
        let mut state = InstallState::sample();
        state.storage_mode = StorageMode::SeparatePools;
        let second_disk = DiskChoice {
            path: "/dev/nvme1n1".to_string(),
            size_gib: 465,
            model: None,
        };
        state.discovered_disks.push(second_disk.clone());
        state.set_disk_role(&second_disk.path, DiskRole::PoolMember);
        // Both disks stay in the default "pool" group.

        let err = StorageLayout::from_state(&state).unwrap_err();

        assert!(err.contains("one install disk per volume group"));
    }

    #[test]
    fn rejects_over_capacity_layout() {
        let mut state = InstallState::sample();
        state.disks[0].size_gib = 100;
        state.discovered_disks[0].size_gib = 100;

        let err = StorageLayout::single_pool_from_state(&state).unwrap_err();

        assert!(err.contains("volume group pool uses"));
    }

    #[test]
    fn plans_storage_actions_for_current_joined_pool_layout() {
        let layout = StorageLayout::single_pool_from_state(&InstallState::sample()).unwrap();

        let actions = layout.actions();

        assert_eq!(
            actions[..3],
            [
                StorageAction::WipeDisk {
                    path: "/dev/nvme0n1".to_string(),
                },
                StorageAction::CreateEsp {
                    path: "/dev/nvme0n1".to_string(),
                },
                StorageAction::JoinVolumeGroup {
                    path: "/dev/nvme0n1".to_string(),
                    vg_name: DEFAULT_LVM_VG_NAME.to_string(),
                },
            ]
        );
        assert!(actions.contains(&StorageAction::FormatLogicalVolume {
            vg_name: DEFAULT_LVM_VG_NAME.to_string(),
            lv_name: "root".to_string(),
        }));
    }

    #[test]
    fn storage_action_labels_are_human_readable() {
        assert_eq!(
            StorageAction::WipeDisk {
                path: "/dev/nvme0n1".to_string()
            }
            .label(),
            "wipe disk /dev/nvme0n1"
        );
        assert!(StorageAction::FormatLogicalVolume {
            vg_name: "pool".to_string(),
            lv_name: "root".to_string(),
        }
        .destructive());
        assert!(!StorageAction::Ignore {
            path: "/dev/sdb".to_string(),
        }
        .destructive());
    }

    #[test]
    fn non_system_roles_are_explicit_non_disko_actions() {
        let mut layout = StorageLayout::single_pool_from_state(&InstallState::sample()).unwrap();
        layout.disks.extend([
            StorageDisk {
                key: "data0".to_string(),
                path: "/dev/sdb".to_string(),
                size_gib: 100,
                role: StorageDiskRole::Data,
                create_esp: false,
                esp_size_mib: 1024,
                lvm_vg: DEFAULT_LVM_VG_NAME.to_string(),
            },
            StorageDisk {
                key: "reserve0".to_string(),
                path: "/dev/sdc".to_string(),
                size_gib: 100,
                role: StorageDiskRole::Reserve,
                create_esp: false,
                esp_size_mib: 1024,
                lvm_vg: DEFAULT_LVM_VG_NAME.to_string(),
            },
            StorageDisk {
                key: "ignore0".to_string(),
                path: "/dev/sdd".to_string(),
                size_gib: 100,
                role: StorageDiskRole::Ignore,
                create_esp: false,
                esp_size_mib: 1024,
                lvm_vg: DEFAULT_LVM_VG_NAME.to_string(),
            },
        ]);

        let actions = layout.actions();

        assert!(actions.contains(&StorageAction::LeaveExisting {
            path: "/dev/sdb".to_string(),
        }));
        assert!(actions.contains(&StorageAction::LeaveExisting {
            path: "/dev/sdc".to_string(),
        }));
        assert!(actions.contains(&StorageAction::Ignore {
            path: "/dev/sdd".to_string(),
        }));
    }

    #[test]
    fn only_system_disks_can_create_esp() {
        let layout = StorageLayout {
            mode: StorageMode::JoinedLvm,
            filesystem: crate::install::state::Filesystem::Btrfs,
            encrypt: false,
            doc_subvolumes: crate::install::state::default_doc_subvolumes(),
            disks: vec![StorageDisk {
                key: "bad".to_string(),
                path: "/dev/sdb".to_string(),
                size_gib: 100,
                role: StorageDiskRole::Data,
                create_esp: true,
                esp_size_mib: 1024,
                lvm_vg: DEFAULT_LVM_VG_NAME.to_string(),
            }],
            volume_groups: vec![StorageVolumeGroup {
                name: DEFAULT_LVM_VG_NAME.to_string(),
                logical_volumes: InstallState::sample().volumes,
            }],
        };

        let err = layout.validate().unwrap_err();

        assert!(err.contains("only system disks can create an ESP"));
    }
}
