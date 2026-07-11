//! Install configuration model. Retains multi-disk/role/storage-mode
//! capability the guided flow does not yet surface, so parts are dead for now.
#![allow(dead_code)]
use std::collections::BTreeMap;

pub const DEFAULT_STORAGE_POOL_NAME: &str = "pool";

#[derive(Debug, Clone)]
pub struct InstallState {
    pub current_step: InstallStep,
    pub scope: InstallScope,
    pub remote: String,
    pub hostname: String,
    pub install_user: String,
    pub mountpoint: String,
    pub role: InstallRole,
    pub allow_ssh: bool,
    pub overwrite_existing_storage: bool,
    pub network_route_cleanup: bool,
    pub storage_mode: StorageMode,
    pub filesystem: Filesystem,
    pub encrypt: bool,
    pub doc_subvolumes: Vec<String>,
    pub discovered_disks: Vec<DiskChoice>,
    pub disks: Vec<DiskChoice>,
    pub disk_roles: BTreeMap<String, DiskRole>,
    pub volume_groups: Vec<VolumeGroupDraft>,
    pub disk_volume_groups: BTreeMap<String, String>,
    pub volume_volume_groups: BTreeMap<String, String>,
    pub volumes: Vec<Volume>,
    pub dotfiles_repo: Option<String>,
    pub skip_bin_ensure: bool,
    /// yescrypt hash for the primary user's password, or None to leave it unset.
    pub user_password_hash: Option<String>,
    pub secrets_ready: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallStep {
    Target,
    Role,
    Disks,
    Pools,
    Volumes,
    Secrets,
    StoragePlan,
    Confirm,
    Install,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallRole {
    Laptop,
    Server,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallScope {
    Remote,
    Local,
}

#[derive(Debug, Clone)]
pub struct DiskChoice {
    pub path: String,
    pub size_gib: u64,
    pub model: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskRole {
    System,
    PoolMember,
    Data,
    Reserve,
    Ignore,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub enum StorageMode {
    SingleDisk,
    JoinedLvm,
    SeparatePools,
    Manual,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Filesystem {
    Btrfs,
    Ext4,
}

impl Filesystem {
    pub fn title(self) -> &'static str {
        match self {
            Filesystem::Btrfs => "btrfs",
            Filesystem::Ext4 => "ext4",
        }
    }

    pub fn next(self) -> Self {
        match self {
            Filesystem::Btrfs => Filesystem::Ext4,
            Filesystem::Ext4 => Filesystem::Btrfs,
        }
    }
}

/// Default btrfs subvolumes carved out of a `/doc` volume, mirroring the shell
/// wizard's `code,data,self,work` layout mounted under `/doc/<name>`.
pub fn default_doc_subvolumes() -> Vec<String> {
    ["code", "data", "self", "work"]
        .into_iter()
        .map(str::to_string)
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Volume {
    pub name: String,
    pub mountpoint: Mountpoint,
    pub size_gib: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VolumeGroupDraft {
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mountpoint {
    Path(String),
    Swap,
}

impl InstallState {
    pub fn draft() -> Self {
        let volumes = default_volumes();
        Self {
            current_step: InstallStep::Target,
            scope: InstallScope::Remote,
            remote: "nixos@10.10.10.7".to_string(),
            hostname: "novo".to_string(),
            install_user: "bresilla".to_string(),
            mountpoint: "/mnt".to_string(),
            role: InstallRole::Laptop,
            allow_ssh: false,
            overwrite_existing_storage: false,
            network_route_cleanup: true,
            // A draft intentionally has no target disk. The TUI fills this
            // from facts; non-interactive calls must provide --disk. Never
            // carry a machine-specific device path into a destructive plan.
            storage_mode: StorageMode::SingleDisk,
            filesystem: Filesystem::Btrfs,
            encrypt: false,
            doc_subvolumes: default_doc_subvolumes(),
            discovered_disks: Vec::new(),
            disks: Vec::new(),
            disk_roles: BTreeMap::new(),
            volume_groups: default_volume_groups(),
            disk_volume_groups: BTreeMap::new(),
            volume_volume_groups: default_volume_assignments(&volumes),
            volumes,
            dotfiles_repo: Some("https://github.com/bresilla/dot.git".to_string()),
            skip_bin_ensure: false,
            user_password_hash: None,
            secrets_ready: false,
        }
    }

    #[cfg(test)]
    pub fn sample() -> Self {
        let default_disk = DiskChoice {
            path: "/dev/nvme0n1".to_string(),
            size_gib: 465,
            model: None,
        };
        let disk_roles = BTreeMap::from([(default_disk.path.clone(), DiskRole::System)]);
        let volumes = default_volumes();
        Self {
            current_step: InstallStep::Volumes,
            scope: InstallScope::Remote,
            remote: "nixos@10.10.10.7".to_string(),
            hostname: "novo".to_string(),
            install_user: "bresilla".to_string(),
            mountpoint: "/mnt".to_string(),
            role: InstallRole::Laptop,
            allow_ssh: true,
            overwrite_existing_storage: false,
            network_route_cleanup: true,
            storage_mode: StorageMode::JoinedLvm,
            filesystem: Filesystem::Btrfs,
            encrypt: false,
            doc_subvolumes: default_doc_subvolumes(),
            discovered_disks: vec![default_disk.clone()],
            disks: vec![default_disk],
            disk_roles,
            volume_groups: default_volume_groups(),
            disk_volume_groups: BTreeMap::from([(
                "/dev/nvme0n1".to_string(),
                DEFAULT_STORAGE_POOL_NAME.to_string(),
            )]),
            volume_volume_groups: default_volume_assignments(&volumes),
            volumes,
            dotfiles_repo: Some("https://github.com/bresilla/dot.git".to_string()),
            skip_bin_ensure: false,
            user_password_hash: None,
            secrets_ready: true,
        }
    }

    pub fn steps() -> &'static [InstallStep] {
        &[
            InstallStep::Target,
            InstallStep::Role,
            InstallStep::Disks,
            InstallStep::Pools,
            InstallStep::Volumes,
            InstallStep::Secrets,
            InstallStep::StoragePlan,
            InstallStep::Confirm,
            InstallStep::Install,
        ]
    }

    pub fn current_step_index(&self) -> usize {
        Self::steps()
            .iter()
            .position(|step| step == &self.current_step)
            .unwrap_or(0)
    }

    pub fn total_disk_gib(&self) -> u64 {
        self.disks.iter().map(|disk| disk.size_gib).sum()
    }

    pub fn used_gib(&self) -> u64 {
        self.volumes.iter().map(|volume| volume.size_gib).sum()
    }

    pub fn free_gib(&self) -> u64 {
        self.total_disk_gib().saturating_sub(self.used_gib())
    }

    pub fn used_ratio(&self) -> f64 {
        let total = self.total_disk_gib();
        if total == 0 {
            0.0
        } else {
            (self.used_gib() as f64 / total as f64).clamp(0.0, 1.0)
        }
    }

    pub fn visible_disks(&self) -> &[DiskChoice] {
        if self.discovered_disks.is_empty() {
            &self.disks
        } else {
            &self.discovered_disks
        }
    }

    pub fn disk_role_for_path(&self, path: &str) -> DiskRole {
        self.disk_roles
            .get(path)
            .copied()
            .or_else(|| {
                self.disks
                    .iter()
                    .position(|disk| disk.path == path)
                    .map(|index| {
                        if index == 0 {
                            DiskRole::System
                        } else {
                            DiskRole::PoolMember
                        }
                    })
            })
            .unwrap_or(DiskRole::Ignore)
    }

    pub fn set_disk_role(&mut self, path: &str, role: DiskRole) {
        if role == DiskRole::System {
            for (other_path, other_role) in &mut self.disk_roles {
                if other_path != path && *other_role == DiskRole::System {
                    *other_role = DiskRole::PoolMember;
                }
            }
        }
        self.disk_roles.insert(path.to_string(), role);
        self.normalize_disk_roles();
    }

    pub fn normalize_disk_roles(&mut self) {
        let visible_disks = self.visible_disks().to_vec();
        let visible_paths = visible_disks
            .iter()
            .map(|disk| disk.path.clone())
            .collect::<std::collections::BTreeSet<_>>();

        self.disk_roles
            .retain(|path, _| visible_paths.contains(path));

        for (index, disk) in visible_disks.iter().enumerate() {
            self.disk_roles.entry(disk.path.clone()).or_insert_with(|| {
                if self.disks.iter().any(|selected| selected.path == disk.path) {
                    if index == 0 {
                        DiskRole::System
                    } else {
                        DiskRole::PoolMember
                    }
                } else {
                    DiskRole::Ignore
                }
            });
        }

        let mut system_seen = false;
        for disk in &visible_disks {
            if self.disk_roles.get(&disk.path) == Some(&DiskRole::System) {
                if system_seen {
                    self.disk_roles
                        .insert(disk.path.clone(), DiskRole::PoolMember);
                } else {
                    system_seen = true;
                }
            }
        }

        if !system_seen {
            let promote = visible_disks
                .iter()
                .find(|disk| self.disk_roles.get(&disk.path) == Some(&DiskRole::PoolMember))
                .or_else(|| visible_disks.first());
            if let Some(disk) = promote {
                self.disk_roles.insert(disk.path.clone(), DiskRole::System);
            }
        }

        self.disks = visible_disks
            .into_iter()
            .filter(|disk| {
                matches!(
                    self.disk_roles.get(&disk.path),
                    Some(DiskRole::System | DiskRole::PoolMember)
                )
            })
            .collect();
        self.normalize_storage_assignments();
    }

    pub fn default_volume_group_name(&self) -> &str {
        self.volume_groups
            .first()
            .map(|group| group.name.as_str())
            .unwrap_or(DEFAULT_STORAGE_POOL_NAME)
    }

    #[allow(dead_code)]
    pub fn ensure_volume_group(&mut self, name: &str) {
        if !self.volume_groups.iter().any(|group| group.name == name) {
            self.volume_groups.push(VolumeGroupDraft {
                name: name.to_string(),
            });
        }
        self.normalize_storage_assignments();
    }

    pub fn create_next_volume_group(&mut self) -> String {
        let mut index = 1;
        loop {
            let name = format!("{DEFAULT_STORAGE_POOL_NAME}{index}");
            if !self.volume_groups.iter().any(|group| group.name == name) {
                self.ensure_volume_group(&name);
                return name;
            }
            index += 1;
        }
    }

    pub fn rename_volume_group(&mut self, old_name: &str, new_name: &str) -> Result<(), String> {
        validate_volume_group_name(new_name)?;
        if old_name == new_name {
            return Ok(());
        }
        if self
            .volume_groups
            .iter()
            .any(|group| group.name == new_name)
        {
            return Err(format!("volume group already exists: {new_name}"));
        }
        let Some(group) = self
            .volume_groups
            .iter_mut()
            .find(|group| group.name == old_name)
        else {
            return Err(format!("volume group not found: {old_name}"));
        };
        group.name = new_name.to_string();
        for value in self.disk_volume_groups.values_mut() {
            if value == old_name {
                *value = new_name.to_string();
            }
        }
        for value in self.volume_volume_groups.values_mut() {
            if value == old_name {
                *value = new_name.to_string();
            }
        }
        self.normalize_storage_assignments();
        Ok(())
    }

    pub fn delete_volume_group_reassigning_to_default(&mut self, name: &str) -> Result<(), String> {
        let default_group = self.default_volume_group_name().to_string();
        if name == default_group {
            return Err("default volume group cannot be deleted".to_string());
        }
        if !self.volume_groups.iter().any(|group| group.name == name) {
            return Err(format!("volume group not found: {name}"));
        }
        for value in self.disk_volume_groups.values_mut() {
            if value == name {
                *value = default_group.clone();
            }
        }
        for value in self.volume_volume_groups.values_mut() {
            if value == name {
                *value = default_group.clone();
            }
        }
        self.volume_groups.retain(|group| group.name != name);
        self.normalize_storage_assignments();
        Ok(())
    }

    pub fn disk_volume_group_for_path(&self, path: &str) -> Option<&str> {
        self.disk_volume_groups
            .get(path)
            .map(String::as_str)
            .or_else(|| {
                if matches!(
                    self.disk_role_for_path(path),
                    DiskRole::System | DiskRole::PoolMember
                ) {
                    Some(self.default_volume_group_name())
                } else {
                    None
                }
            })
    }

    #[allow(dead_code)]
    pub fn set_disk_volume_group(&mut self, path: &str, volume_group: &str) {
        self.ensure_volume_group(volume_group);
        self.disk_volume_groups
            .insert(path.to_string(), volume_group.to_string());
        self.normalize_storage_assignments();
    }

    pub fn volume_group_for_volume(&self, name: &str) -> &str {
        self.volume_volume_groups
            .get(name)
            .map(String::as_str)
            .unwrap_or_else(|| self.default_volume_group_name())
    }

    #[allow(dead_code)]
    pub fn set_volume_group_for_volume(&mut self, volume_name: &str, volume_group: &str) {
        self.ensure_volume_group(volume_group);
        self.volume_volume_groups
            .insert(volume_name.to_string(), volume_group.to_string());
        self.normalize_storage_assignments();
    }

    pub fn normalize_storage_assignments(&mut self) {
        if self.volume_groups.is_empty() {
            self.volume_groups.push(VolumeGroupDraft {
                name: DEFAULT_STORAGE_POOL_NAME.to_string(),
            });
        }

        let valid_groups = self
            .volume_groups
            .iter()
            .map(|group| group.name.clone())
            .collect::<std::collections::BTreeSet<_>>();
        let default_group = self.default_volume_group_name().to_string();
        let selected_paths = self
            .disks
            .iter()
            .map(|disk| disk.path.clone())
            .collect::<std::collections::BTreeSet<_>>();

        self.disk_volume_groups
            .retain(|path, group| selected_paths.contains(path) && valid_groups.contains(group));
        for disk in &self.disks {
            self.disk_volume_groups
                .entry(disk.path.clone())
                .or_insert_with(|| default_group.clone());
        }

        let volume_names = self
            .volumes
            .iter()
            .map(|volume| volume.name.clone())
            .collect::<std::collections::BTreeSet<_>>();
        self.volume_volume_groups
            .retain(|name, group| volume_names.contains(name) && valid_groups.contains(group));
        for volume in &self.volumes {
            self.volume_volume_groups
                .entry(volume.name.clone())
                .or_insert_with(|| default_group.clone());
        }
    }
}

fn default_volumes() -> Vec<Volume> {
    vec![
        Volume::filesystem("root", "/", 32).expect("default root mountpoint is valid"),
        Volume::filesystem("home", "/home", 32).expect("default home mountpoint is valid"),
        Volume::filesystem("docs", "/doc", 128).expect("default docs mountpoint is valid"),
        Volume::filesystem("nix", "/nix", 160).expect("default nix mountpoint is valid"),
        Volume::filesystem("pkg", "/pkg", 32).expect("default pkg mountpoint is valid"),
        Volume::swap("swap", 64),
    ]
}

fn default_volume_groups() -> Vec<VolumeGroupDraft> {
    vec![VolumeGroupDraft {
        name: DEFAULT_STORAGE_POOL_NAME.to_string(),
    }]
}

fn default_volume_assignments(volumes: &[Volume]) -> BTreeMap<String, String> {
    volumes
        .iter()
        .map(|volume| (volume.name.clone(), DEFAULT_STORAGE_POOL_NAME.to_string()))
        .collect()
}

fn validate_volume_group_name(name: &str) -> Result<(), String> {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return Err("volume group name cannot be empty".to_string());
    };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return Err(format!("invalid volume group name: {name}"));
    }
    if chars.all(|ch| ch.is_ascii_alphanumeric() || ch == '_') {
        Ok(())
    } else {
        Err(format!("invalid volume group name: {name}"))
    }
}

impl InstallStep {
    pub fn title(self) -> &'static str {
        match self {
            InstallStep::Target => "target",
            InstallStep::Role => "role",
            InstallStep::Disks => "disks",
            InstallStep::Pools => "pools",
            InstallStep::Volumes => "volumes",
            InstallStep::Secrets => "secrets",
            InstallStep::StoragePlan => "plan",
            InstallStep::Confirm => "confirm",
            InstallStep::Install => "install",
        }
    }
}

impl InstallRole {
    pub fn all() -> &'static [InstallRole] {
        &[InstallRole::Laptop, InstallRole::Server]
    }

    pub fn title(self) -> &'static str {
        match self {
            InstallRole::Laptop => "laptop",
            InstallRole::Server => "server",
        }
    }

    pub fn previous(self) -> Self {
        match self {
            InstallRole::Laptop => InstallRole::Server,
            InstallRole::Server => InstallRole::Laptop,
        }
    }

    pub fn next(self) -> Self {
        match self {
            InstallRole::Laptop => InstallRole::Server,
            InstallRole::Server => InstallRole::Laptop,
        }
    }
}

impl InstallScope {
    pub fn title(self) -> &'static str {
        match self {
            InstallScope::Remote => "remote",
            InstallScope::Local => "local",
        }
    }

    pub fn next(self) -> Self {
        match self {
            InstallScope::Remote => InstallScope::Local,
            InstallScope::Local => InstallScope::Remote,
        }
    }
}

impl DiskRole {
    pub fn title(self) -> &'static str {
        match self {
            DiskRole::System => "system",
            DiskRole::PoolMember => "pool",
            DiskRole::Data => "data",
            DiskRole::Reserve => "reserve",
            DiskRole::Ignore => "ignore",
        }
    }

    pub fn marker(self) -> &'static str {
        match self {
            DiskRole::System => "[S]",
            DiskRole::PoolMember => "[P]",
            DiskRole::Data => "[D]",
            DiskRole::Reserve => "[R]",
            DiskRole::Ignore => "[ ]",
        }
    }

    pub fn next(self) -> Self {
        match self {
            DiskRole::System => DiskRole::PoolMember,
            DiskRole::PoolMember => DiskRole::Data,
            DiskRole::Data => DiskRole::Reserve,
            DiskRole::Reserve => DiskRole::Ignore,
            DiskRole::Ignore => DiskRole::System,
        }
    }
}

impl StorageMode {
    pub fn title(self) -> &'static str {
        match self {
            StorageMode::SingleDisk => "single-disk",
            StorageMode::JoinedLvm => "joined-lvm",
            StorageMode::SeparatePools => "separate-pools",
            StorageMode::Manual => "manual",
        }
    }

    pub fn next_supported(self) -> Self {
        match self {
            StorageMode::SingleDisk => StorageMode::JoinedLvm,
            StorageMode::JoinedLvm => StorageMode::SingleDisk,
            StorageMode::SeparatePools | StorageMode::Manual => StorageMode::JoinedLvm,
        }
    }
}

impl Volume {
    pub fn filesystem(name: &str, mountpoint: &str, size_gib: u64) -> Result<Self, String> {
        validate_mountpoint(mountpoint)?;
        Ok(Self {
            name: name.to_string(),
            mountpoint: Mountpoint::Path(mountpoint.to_string()),
            size_gib,
        })
    }

    pub fn swap(name: &str, size_gib: u64) -> Self {
        Self {
            name: name.to_string(),
            mountpoint: Mountpoint::Swap,
            size_gib,
        }
    }
}

impl Mountpoint {
    pub fn label(&self) -> &str {
        match self {
            Mountpoint::Path(path) => path,
            Mountpoint::Swap => "swap",
        }
    }
}

pub fn validate_mountpoint(value: &str) -> Result<(), String> {
    if value == "/" {
        return Ok(());
    }
    if !value.starts_with('/') {
        return Err(format!("mountpoint must be absolute: {value}"));
    }
    if value.len() == 1 || value.ends_with('/') || value.contains("//") {
        return Err(format!("invalid mountpoint shape: {value}"));
    }
    if !value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'-' | b'_'))
    {
        return Err(format!(
            "mountpoint contains unsupported characters: {value}"
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        validate_mountpoint, DiskChoice, DiskRole, InstallRole, InstallState, StorageMode,
    };

    #[test]
    fn root_mountpoint_is_valid() {
        assert!(validate_mountpoint("/").is_ok());
    }

    #[test]
    fn rejects_relative_mountpoints() {
        assert!(validate_mountpoint("home").is_err());
        assert!(validate_mountpoint("swap").is_err());
    }

    #[test]
    fn rejects_weird_mountpoints() {
        assert!(validate_mountpoint("/home/user space").is_err());
        assert!(validate_mountpoint("/home/").is_err());
        assert!(validate_mountpoint("/home//cache").is_err());
    }

    #[test]
    fn computes_capacity_summary() {
        let state = InstallState::sample();
        assert_eq!(state.total_disk_gib(), 465);
        assert_eq!(state.used_gib(), 448);
        assert_eq!(state.free_gib(), 17);
        assert!(state.used_ratio() > 0.96);
    }

    #[test]
    fn role_titles_match_installer_values() {
        assert_eq!(InstallRole::Laptop.title(), "laptop");
        assert_eq!(InstallRole::Server.title(), "server");
    }

    #[test]
    fn storage_mode_titles_match_installer_values() {
        assert_eq!(StorageMode::SingleDisk.title(), "single-disk");
        assert_eq!(StorageMode::JoinedLvm.title(), "joined-lvm");
        assert_eq!(StorageMode::SeparatePools.title(), "separate-pools");
        assert_eq!(StorageMode::Manual.title(), "manual");
    }

    #[test]
    fn draft_starts_at_target_with_locked_secrets() {
        let state = InstallState::draft();
        assert_eq!(state.current_step.title(), "target");
        assert!(!state.secrets_ready);
        assert!(state.disks.is_empty());
        assert!(state.discovered_disks.is_empty());
        assert!(state.disk_roles.is_empty());
    }

    #[test]
    fn defaults_assign_all_install_storage_to_pool() {
        let state = InstallState::sample();

        assert_eq!(state.default_volume_group_name(), "pool");
        assert_eq!(
            state.disk_volume_group_for_path("/dev/nvme0n1"),
            Some("pool")
        );
        for volume in &state.volumes {
            assert_eq!(state.volume_group_for_volume(&volume.name), "pool");
        }
    }

    #[test]
    fn normalizes_storage_assignments_after_disk_roles_change() {
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

        assert_eq!(
            state.disk_volume_group_for_path(&second_disk.path),
            Some("extra")
        );
        assert_eq!(state.volume_group_for_volume("pkg"), "extra");

        state.set_disk_role(&second_disk.path, DiskRole::Ignore);

        assert_eq!(state.disk_volume_group_for_path(&second_disk.path), None);
        assert_eq!(state.volume_group_for_volume("pkg"), "extra");
    }

    #[test]
    fn creates_next_volume_group_name_without_collisions() {
        let mut state = InstallState::sample();

        assert_eq!(state.create_next_volume_group(), "pool1");
        assert_eq!(state.create_next_volume_group(), "pool2");
        assert!(state
            .volume_groups
            .iter()
            .any(|group| group.name == "pool1"));
        assert!(state
            .volume_groups
            .iter()
            .any(|group| group.name == "pool2"));
    }

    #[test]
    fn renames_volume_group_and_updates_assignments() {
        let mut state = InstallState::sample();
        state.ensure_volume_group("extra");
        state.set_disk_volume_group("/dev/nvme0n1", "extra");
        state.set_volume_group_for_volume("pkg", "extra");

        state.rename_volume_group("extra", "archive").unwrap();

        assert_eq!(
            state.disk_volume_group_for_path("/dev/nvme0n1"),
            Some("archive")
        );
        assert_eq!(state.volume_group_for_volume("pkg"), "archive");
        assert!(state
            .volume_groups
            .iter()
            .any(|group| group.name == "archive"));
        assert!(!state
            .volume_groups
            .iter()
            .any(|group| group.name == "extra"));
    }

    #[test]
    fn deletes_volume_group_by_reassigning_to_default() {
        let mut state = InstallState::sample();
        state.ensure_volume_group("extra");
        state.set_disk_volume_group("/dev/nvme0n1", "extra");
        state.set_volume_group_for_volume("pkg", "extra");

        state
            .delete_volume_group_reassigning_to_default("extra")
            .unwrap();

        assert_eq!(
            state.disk_volume_group_for_path("/dev/nvme0n1"),
            Some("pool")
        );
        assert_eq!(state.volume_group_for_volume("pkg"), "pool");
        assert!(!state
            .volume_groups
            .iter()
            .any(|group| group.name == "extra"));
    }

    #[test]
    fn rejects_deleting_default_volume_group() {
        let mut state = InstallState::sample();

        let err = state
            .delete_volume_group_reassigning_to_default("pool")
            .unwrap_err();

        assert!(err.contains("default volume group cannot be deleted"));
    }
}
