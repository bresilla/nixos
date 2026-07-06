#[derive(Debug, Clone)]
pub struct InstallState {
    pub current_step: InstallStep,
    pub scope: InstallScope,
    pub remote: String,
    pub hostname: String,
    pub install_user: String,
    pub mountpoint: String,
    pub role: InstallRole,
    pub disks: Vec<DiskChoice>,
    pub volumes: Vec<Volume>,
    pub dotfiles_repo: Option<String>,
    pub secrets_ready: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallStep {
    Target,
    Role,
    Disks,
    Volumes,
    Secrets,
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

#[derive(Debug, Clone)]
pub struct Volume {
    pub name: String,
    pub mountpoint: Mountpoint,
    pub size_gib: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mountpoint {
    Path(String),
    Swap,
}

impl InstallState {
    pub fn draft() -> Self {
        Self {
            current_step: InstallStep::Target,
            scope: InstallScope::Remote,
            remote: "nixos@10.10.10.7".to_string(),
            hostname: "novo".to_string(),
            install_user: "bresilla".to_string(),
            mountpoint: "/mnt".to_string(),
            role: InstallRole::Laptop,
            disks: vec![DiskChoice {
                path: "/dev/nvme0n1".to_string(),
                size_gib: 465,
                model: None,
            }],
            volumes: default_volumes(),
            dotfiles_repo: Some("https://github.com/bresilla/dot.git".to_string()),
            secrets_ready: false,
        }
    }

    #[cfg(test)]
    pub fn sample() -> Self {
        Self {
            current_step: InstallStep::Volumes,
            scope: InstallScope::Remote,
            remote: "nixos@10.10.10.7".to_string(),
            hostname: "novo".to_string(),
            install_user: "bresilla".to_string(),
            mountpoint: "/mnt".to_string(),
            role: InstallRole::Laptop,
            disks: vec![DiskChoice {
                path: "/dev/nvme0n1".to_string(),
                size_gib: 465,
                model: None,
            }],
            volumes: default_volumes(),
            dotfiles_repo: Some("https://github.com/bresilla/dot.git".to_string()),
            secrets_ready: true,
        }
    }

    pub fn steps() -> &'static [InstallStep] {
        &[
            InstallStep::Target,
            InstallStep::Role,
            InstallStep::Disks,
            InstallStep::Volumes,
            InstallStep::Secrets,
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

impl InstallStep {
    pub fn title(self) -> &'static str {
        match self {
            InstallStep::Target => "target",
            InstallStep::Role => "role",
            InstallStep::Disks => "disks",
            InstallStep::Volumes => "volumes",
            InstallStep::Secrets => "secrets",
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
    use super::{validate_mountpoint, InstallRole, InstallState};

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
    fn draft_starts_at_target_with_locked_secrets() {
        let state = InstallState::draft();
        assert_eq!(state.current_step.title(), "target");
        assert!(!state.secrets_ready);
    }
}
