//! Guided, one-question-at-a-time install flow.
//!
//! Instead of a dense dashboard where every field is editable at once, the
//! wizard walks the user through a linear sequence of single decisions:
//! scope → (remote) → hostname → user → password → role → ssh → disk →
//! filesystem → encryption → overwrite → dotfiles → review → confirm.
//!
//! Each step is one screen with one question. Volumes and the pool layout use
//! sensible defaults (from [`InstallState::draft`]) so the common case needs no
//! per-volume fiddling; capacity is validated at review time.

use crate::facts::TargetFacts;
use crate::install::preflight::PreflightReport;
use crate::install::state::{
    DiskChoice, DiskRole, Filesystem, InstallRole, InstallScope, InstallState,
    DEFAULT_STORAGE_POOL_NAME,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Scope,
    Remote,
    Hostname,
    User,
    Password,
    Role,
    Ssh,
    Disk,
    Filesystem,
    Encrypt,
    Overwrite,
    Dotfiles,
    Review,
    Confirm,
}

impl Step {
    pub fn name(self) -> &'static str {
        match self {
            Step::Scope => "scope",
            Step::Remote => "remote",
            Step::Hostname => "hostname",
            Step::User => "user",
            Step::Password => "password",
            Step::Role => "role",
            Step::Ssh => "ssh",
            Step::Disk => "disk",
            Step::Filesystem => "filesystem",
            Step::Encrypt => "encryption",
            Step::Overwrite => "overwrite",
            Step::Dotfiles => "dotfiles",
            Step::Review => "review",
            Step::Confirm => "confirm",
        }
    }

    pub fn question(self) -> &'static str {
        match self {
            Step::Scope => "Where do you want to install?",
            Step::Remote => "Which machine? (user@host)",
            Step::Hostname => "What should the machine be called?",
            Step::User => "What is your username?",
            Step::Password => "Set a login password",
            Step::Role => "What kind of system is this?",
            Step::Ssh => "Enable the SSH server?",
            Step::Disk => "Which disk should it install to?",
            Step::Filesystem => "Which filesystem?",
            Step::Encrypt => "Encrypt the disk?",
            Step::Overwrite => "Existing data on the disk?",
            Step::Dotfiles => "Dotfiles repository (optional)",
            Step::Review => "Review the plan",
            Step::Confirm => "Confirm — this will erase the disk",
        }
    }

    pub fn help(self) -> &'static str {
        match self {
            Step::Scope => "Local installs onto this machine; remote installs onto another over SSH.",
            Step::Remote => "The target must be reachable over SSH with key auth.",
            Step::Hostname => "Lowercase letters, digits and dashes.",
            Step::User => "Your primary account; gets sudo.",
            Step::Password => "Leave blank for a password-less account. Hidden as you type.",
            Step::Role => "Laptop adds a desktop; server is headless.",
            Step::Ssh => "Turn on the OpenSSH daemon at boot.",
            Step::Disk => "Every partition on this disk will be replaced.",
            Step::Filesystem => "btrfs supports subvolumes and snapshots; ext4 is simpler.",
            Step::Encrypt => "Full-disk encryption (LUKS). You'll set a passphrase at boot.",
            Step::Overwrite => "Allow wiping an existing LVM volume group if one is present.",
            Step::Dotfiles => "Cloned for your user after install. Leave blank to skip.",
            Step::Review => "Check the summary, then run preflight before continuing.",
            Step::Confirm => "Type the phrase exactly to unlock the install.",
        }
    }

    pub fn kind(self) -> StepKind {
        match self {
            Step::Scope
            | Step::Role
            | Step::Ssh
            | Step::Filesystem
            | Step::Encrypt
            | Step::Overwrite => StepKind::Choice,
            Step::Remote | Step::Hostname | Step::User | Step::Dotfiles => StepKind::Text,
            Step::Password => StepKind::Password,
            Step::Disk => StepKind::Disk,
            Step::Review => StepKind::Review,
            Step::Confirm => StepKind::Confirm,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepKind {
    Choice,
    Text,
    Password,
    Disk,
    Review,
    Confirm,
}

/// One selectable option: a short label and a one-line description.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opt {
    pub label: String,
    pub desc: String,
}

impl Opt {
    fn new(label: &str, desc: &str) -> Self {
        Self {
            label: label.to_string(),
            desc: desc.to_string(),
        }
    }
}

pub struct Flow {
    pub state: InstallState,
    pub pos: usize,
    /// Highlighted option for Choice/Disk steps.
    pub cursor: usize,
    /// Working text buffer for Text/Password steps.
    pub buffer: String,
    /// Working buffer for the Confirm phrase.
    pub confirm_input: String,
    /// Plaintext password (hashed into state just before install).
    pub password: String,
    pub status: String,
    pub preflight: Option<PreflightReport>,
    pub facts: Option<TargetFacts>,
    /// Set while the disk step is fetching facts; the UI shows a spinner.
    pub disk_error: Option<String>,
    /// The flow is finished and the caller should start the install.
    pub done: bool,
    pub quit: bool,
}

impl Flow {
    pub fn new(state: InstallState) -> Self {
        let mut flow = Self {
            state,
            pos: 0,
            cursor: 0,
            buffer: String::new(),
            confirm_input: String::new(),
            password: String::new(),
            status: String::new(),
            preflight: None,
            facts: None,
            disk_error: None,
            done: false,
            quit: false,
        };
        flow.load();
        flow
    }

    /// The active linear sequence. The remote-host step only appears for remote
    /// installs.
    pub fn steps(&self) -> Vec<Step> {
        let mut steps = vec![Step::Scope];
        if self.state.scope == InstallScope::Remote {
            steps.push(Step::Remote);
        }
        steps.extend([
            Step::Hostname,
            Step::User,
            Step::Password,
            Step::Role,
            Step::Ssh,
            Step::Disk,
            Step::Filesystem,
            Step::Encrypt,
            Step::Overwrite,
            Step::Dotfiles,
            Step::Review,
            Step::Confirm,
        ]);
        steps
    }

    pub fn current(&self) -> Step {
        let steps = self.steps();
        steps[self.pos.min(steps.len() - 1)]
    }

    pub fn prev_step(&self) -> Option<Step> {
        let steps = self.steps();
        self.pos.checked_sub(1).map(|i| steps[i])
    }

    pub fn next_step(&self) -> Option<Step> {
        let steps = self.steps();
        steps.get(self.pos + 1).copied()
    }

    pub fn step_number(&self) -> (usize, usize) {
        (self.pos + 1, self.steps().len())
    }

    /// Options for the current Choice/Disk step, and which one is selected.
    pub fn options(&self) -> Vec<Opt> {
        match self.current() {
            Step::Scope => vec![
                Opt::new("local", "install onto this machine"),
                Opt::new("remote", "install onto another machine over SSH"),
            ],
            Step::Role => vec![
                Opt::new("laptop", "graphical desktop"),
                Opt::new("server", "headless"),
            ],
            Step::Ssh => vec![
                Opt::new("disabled", "no SSH server"),
                Opt::new("enabled", "start OpenSSH at boot"),
            ],
            Step::Filesystem => vec![
                Opt::new("btrfs", "subvolumes + snapshots"),
                Opt::new("ext4", "simple and battle-tested"),
            ],
            Step::Encrypt => vec![
                Opt::new("no", "no disk encryption"),
                Opt::new("yes", "LUKS full-disk encryption"),
            ],
            Step::Overwrite => vec![
                Opt::new("keep", "fail if an existing pool is present"),
                Opt::new("wipe", "remove any existing LVM volume group"),
            ],
            Step::Disk => self
                .disk_candidates()
                .iter()
                .map(|disk| {
                    Opt::new(
                        &disk.path,
                        &format!(
                            "{}G · {}",
                            disk.size_gib,
                            disk.model.as_deref().unwrap_or("disk")
                        ),
                    )
                })
                .collect(),
            _ => Vec::new(),
        }
    }

    fn disk_candidates(&self) -> Vec<DiskChoice> {
        if !self.state.discovered_disks.is_empty() {
            self.state.discovered_disks.clone()
        } else {
            self.state.disks.clone()
        }
    }

    /// Prepare cursor/buffer for the step we just moved to.
    fn load(&mut self) {
        self.cursor = 0;
        self.buffer.clear();
        self.disk_error = None;
        match self.current() {
            Step::Scope => {
                self.cursor = match self.state.scope {
                    InstallScope::Local => 0,
                    InstallScope::Remote => 1,
                }
            }
            Step::Role => {
                self.cursor = match self.state.role {
                    InstallRole::Laptop => 0,
                    InstallRole::Server => 1,
                }
            }
            Step::Ssh => self.cursor = usize::from(self.state.allow_ssh),
            Step::Filesystem => {
                self.cursor = match self.state.filesystem {
                    Filesystem::Btrfs => 0,
                    Filesystem::Ext4 => 1,
                }
            }
            Step::Encrypt => self.cursor = usize::from(self.state.encrypt),
            Step::Overwrite => self.cursor = usize::from(self.state.overwrite_existing_storage),
            Step::Remote => self.buffer = self.state.remote.clone(),
            Step::Hostname => self.buffer = self.state.hostname.clone(),
            Step::User => self.buffer = self.state.install_user.clone(),
            Step::Dotfiles => {
                self.buffer = self.state.dotfiles_repo.clone().unwrap_or_default()
            }
            Step::Disk => {
                self.discover_disks();
                let current = self.state.disks.first().map(|disk| disk.path.clone());
                if let Some(path) = current {
                    if let Some(index) = self
                        .disk_candidates()
                        .iter()
                        .position(|disk| disk.path == path)
                    {
                        self.cursor = index;
                    }
                }
            }
            _ => {}
        }
    }

    /// Run facts-based discovery for the disk step. Blocking; the caller shows a
    /// status line. Remote uses a single SSH round trip, local reads directly.
    fn discover_disks(&mut self) {
        let facts = match self.state.scope {
            InstallScope::Local => crate::facts::collect(),
            InstallScope::Remote => match crate::facts::collect_over_ssh(&self.state.remote) {
                Ok(facts) => facts,
                Err(err) => {
                    self.disk_error = Some(err);
                    return;
                }
            },
        };
        let disks = crate::facts::disk_choices(&facts);
        if !disks.is_empty() {
            self.state.discovered_disks = disks;
        }
        self.facts = Some(facts);
    }

    // ── navigation ──────────────────────────────────────────────

    pub fn select_next(&mut self) {
        let len = self.options().len();
        if len > 0 {
            self.cursor = (self.cursor + 1) % len;
        }
    }

    pub fn select_prev(&mut self) {
        let len = self.options().len();
        if len > 0 {
            self.cursor = (self.cursor + len - 1) % len;
        }
    }

    pub fn insert(&mut self, ch: char) {
        match self.current().kind() {
            StepKind::Password => {
                if !ch.is_control() {
                    self.password.push(ch);
                }
            }
            StepKind::Text => {
                if !ch.is_control() {
                    self.buffer.push(ch);
                }
            }
            StepKind::Confirm => {
                if !ch.is_control() {
                    self.confirm_input.push(ch);
                }
            }
            _ => {}
        }
    }

    pub fn backspace(&mut self) {
        match self.current().kind() {
            StepKind::Password => {
                self.password.pop();
            }
            StepKind::Text => {
                self.buffer.pop();
            }
            StepKind::Confirm => {
                self.confirm_input.pop();
            }
            _ => {}
        }
    }

    pub fn back(&mut self) {
        if self.pos == 0 {
            return;
        }
        self.pos -= 1;
        self.load();
    }

    /// Accept the current step and advance. Returns an error message for the
    /// status line on validation failure (the flow does not advance).
    pub fn advance(&mut self) {
        match self.commit() {
            Ok(()) => {}
            Err(err) => {
                self.status = err;
                return;
            }
        }
        self.status.clear();

        if self.current() == Step::Confirm {
            self.done = true;
            return;
        }

        let len = self.steps().len();
        if self.pos + 1 < len {
            self.pos += 1;
            self.load();
        }
    }

    /// Write the current step's answer into the install state, validating it.
    fn commit(&mut self) -> Result<(), String> {
        match self.current() {
            Step::Scope => {
                self.state.scope = if self.cursor == 0 {
                    InstallScope::Local
                } else {
                    InstallScope::Remote
                };
            }
            Step::Role => {
                self.state.role = if self.cursor == 0 {
                    InstallRole::Laptop
                } else {
                    InstallRole::Server
                };
            }
            Step::Ssh => self.state.allow_ssh = self.cursor == 1,
            Step::Filesystem => {
                self.state.filesystem = if self.cursor == 0 {
                    Filesystem::Btrfs
                } else {
                    Filesystem::Ext4
                };
            }
            Step::Encrypt => self.state.encrypt = self.cursor == 1,
            Step::Overwrite => self.state.overwrite_existing_storage = self.cursor == 1,
            Step::Remote => {
                let value = self.buffer.trim();
                if !value.contains('@') || value.starts_with('@') || value.ends_with('@') {
                    return Err("remote should look like user@host".to_string());
                }
                self.state.remote = value.to_string();
            }
            Step::Hostname => {
                let value = self.buffer.trim();
                validate_hostname(value)?;
                self.state.hostname = value.to_string();
            }
            Step::User => {
                let value = self.buffer.trim();
                validate_username(value)?;
                self.state.install_user = value.to_string();
            }
            Step::Dotfiles => {
                let value = self.buffer.trim();
                self.state.dotfiles_repo = if value.is_empty() {
                    None
                } else {
                    Some(value.to_string())
                };
            }
            Step::Password => {
                // Committed here (kept plaintext); hashed into state at install.
            }
            Step::Disk => {
                let candidates = self.disk_candidates();
                let disk = candidates
                    .get(self.cursor)
                    .cloned()
                    .ok_or_else(|| "no disk selected".to_string())?;
                self.set_primary_disk(disk);
            }
            Step::Review => {
                if !self
                    .preflight
                    .as_ref()
                    .is_some_and(PreflightReport::pass)
                {
                    return Err("run preflight (space) and resolve failures first".to_string());
                }
            }
            Step::Confirm => {
                if self.confirm_input.trim() != self.confirm_phrase() {
                    return Err("confirmation phrase does not match".to_string());
                }
            }
        }
        Ok(())
    }

    /// Point the whole (single-disk, joined-LVM) layout at the chosen disk.
    fn set_primary_disk(&mut self, disk: DiskChoice) {
        let path = disk.path.clone();
        self.state.disks = vec![disk];
        self.state.disk_roles.clear();
        self.state.disk_roles.insert(path.clone(), DiskRole::System);
        self.state.disk_volume_groups.clear();
        self.state
            .disk_volume_groups
            .insert(path, DEFAULT_STORAGE_POOL_NAME.to_string());
        self.state.normalize_disk_roles();
    }

    /// Toggle used on Review (run preflight) and as a generic space action.
    pub fn toggle(&mut self, repo: &std::path::Path) {
        if self.current() == Step::Review {
            let report = crate::install::preflight::run(repo, &self.state);
            self.preflight = Some(report);
            self.status = "preflight complete".to_string();
        }
    }

    pub fn confirm_phrase(&self) -> String {
        crate::install::confirm::DestructiveConfirmation::from_state(&self.state).phrase
    }

    pub fn confirm_armed(&self) -> bool {
        self.confirm_input.trim() == self.confirm_phrase()
    }

    /// Hash the entered password into the install state, just before install.
    pub fn commit_password(&mut self) -> Result<(), String> {
        if self.password.is_empty() {
            self.state.user_password_hash = None;
        } else {
            self.state.user_password_hash =
                Some(crate::install::secrets::hash_password(&self.password)?);
        }
        Ok(())
    }
}

fn validate_hostname(value: &str) -> Result<(), String> {
    if value.is_empty() {
        return Err("hostname is required".to_string());
    }
    if value.len() > 63
        || !value
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        || value.starts_with('-')
        || value.ends_with('-')
    {
        return Err("hostname: lowercase letters, digits, dashes".to_string());
    }
    Ok(())
}

fn validate_username(value: &str) -> Result<(), String> {
    let mut chars = value.chars();
    match chars.next() {
        None => return Err("username is required".to_string()),
        Some(c) if !(c.is_ascii_lowercase() || c == '_') => {
            return Err("username must start with a lowercase letter".to_string())
        }
        _ => {}
    }
    if chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-') {
        Ok(())
    } else {
        Err("username: lowercase letters, digits, _ and -".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flow() -> Flow {
        Flow::new(InstallState::draft())
    }

    #[test]
    fn local_scope_skips_remote_step() {
        let mut f = flow();
        assert_eq!(f.current(), Step::Scope);
        // choose local
        f.cursor = 0;
        f.advance();
        assert_eq!(f.current(), Step::Hostname);
        assert_eq!(f.state.scope, InstallScope::Local);
        assert!(!f.steps().contains(&Step::Remote));
    }

    #[test]
    fn remote_scope_inserts_remote_step() {
        let mut f = flow();
        f.cursor = 1; // remote
        f.advance();
        assert_eq!(f.current(), Step::Remote);
        assert!(f.steps().contains(&Step::Remote));
    }

    #[test]
    fn remote_requires_user_at_host() {
        let mut f = flow();
        f.cursor = 1;
        f.advance(); // -> Remote
        f.buffer = "not-a-host".to_string();
        f.advance();
        assert_eq!(f.current(), Step::Remote); // rejected
        assert!(f.status.contains("user@host"));
        f.buffer = "nixos@10.0.0.5".to_string();
        f.advance();
        assert_eq!(f.current(), Step::Hostname);
        assert_eq!(f.state.remote, "nixos@10.0.0.5");
    }

    #[test]
    fn hostname_validation() {
        let mut f = flow();
        f.cursor = 0;
        f.advance(); // Hostname
        f.buffer = "Bad Host".to_string();
        f.advance();
        assert_eq!(f.current(), Step::Hostname);
        f.buffer = "novo".to_string();
        f.advance();
        assert_eq!(f.current(), Step::User);
    }

    #[test]
    fn back_returns_to_previous_and_reloads() {
        let mut f = flow();
        f.cursor = 0;
        f.advance(); // Hostname
        f.buffer = "novo".to_string();
        f.advance(); // User
        f.back();
        assert_eq!(f.current(), Step::Hostname);
        assert_eq!(f.buffer, "novo"); // reloaded from state
    }

    #[test]
    fn choice_cursor_maps_to_state() {
        let mut f = flow();
        f.cursor = 0;
        f.advance(); // Hostname (local)
        // jump ahead to role via advances with valid values
        f.buffer = "novo".to_string();
        f.advance(); // User
        f.buffer = "bresilla".to_string();
        f.advance(); // Password
        f.advance(); // Role
        assert_eq!(f.current(), Step::Role);
        f.cursor = 1; // server
        f.advance(); // Ssh
        assert_eq!(f.state.role, InstallRole::Server);
    }

    #[test]
    fn password_is_hashed_only_when_set() {
        let mut f = flow();
        f.commit_password().unwrap();
        assert_eq!(f.state.user_password_hash, None);
    }

    #[test]
    fn step_numbering_reflects_scope() {
        let mut f = flow();
        // remote flow has one more step than local
        f.cursor = 1;
        f.advance();
        let (_, remote_total) = f.step_number();
        let mut g = flow();
        g.cursor = 0;
        g.advance();
        let (_, local_total) = g.step_number();
        assert_eq!(remote_total, local_total + 1);
    }
}
