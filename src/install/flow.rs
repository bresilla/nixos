//! Guided install flow — one focused screen per decision, but with **every**
//! knob exposed. Simple choices (scope, role, filesystem, …) are one-question
//! cards; the storage layout is edited through four focused list editors
//! (disks, pools, volumes, doc-subvolumes), each tweaked one item/field at a
//! time. Nothing from the install model is hidden.

use std::collections::BTreeSet;
use std::sync::mpsc::{self, Receiver, TryRecvError};

use tui_input::{Input, InputRequest};

use crate::facts::TargetFacts;
use crate::install::preflight::PreflightReport;
use crate::install::state::{
    validate_mountpoint, DiskChoice, DiskRole, Filesystem, InstallRole, InstallScope, InstallState,
    Mountpoint, StorageMode, Volume, VolumeGroupDraft, DEFAULT_STORAGE_POOL_NAME,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Scope,
    Remote,
    Mountpoint,
    Hostname,
    User,
    Password,
    PasswordConfirm,
    Role,
    Ssh,
    Locale,
    Lvm,
    Encrypt,
    Filesystem,
    Disks,
    #[allow(dead_code)]
    StorageMode,
    Efi,
    Storage,
    ExtraDisks,
    // Retained for the generic editor + manual paths; the Storage two-panel
    // editor now covers pools/volumes in the default flow.
    #[allow(dead_code)]
    Pools,
    #[allow(dead_code)]
    Volumes,
    DocSubvols,
    Overwrite,
    NetworkCleanup,
    BinEnsure,
    Dotfiles,
    Review,
    Confirm,
}

impl Step {
    pub fn name(self) -> &'static str {
        match self {
            Step::Scope => "scope",
            Step::Remote => "remote",
            Step::Mountpoint => "mountpoint",
            Step::Hostname => "hostname",
            Step::User => "user",
            Step::Password => "password",
            Step::PasswordConfirm => "confirm password",
            Step::Role => "role",
            Step::Ssh => "ssh",
            Step::Locale => "locale",
            Step::Filesystem => "filesystem",
            Step::Encrypt => "encryption",
            Step::StorageMode => "storage mode",
            Step::Lvm => "lvm",
            Step::Disks => "disk",
            Step::Efi => "boot",
            Step::Storage => "storage",
            Step::ExtraDisks => "extra disks",
            Step::Pools => "pools",
            Step::Volumes => "volumes",
            Step::DocSubvols => "doc subvolumes",
            Step::Overwrite => "overwrite",
            Step::NetworkCleanup => "network cleanup",
            Step::BinEnsure => "bin provisioning",
            Step::Dotfiles => "dotfiles",
            Step::Review => "review",
            Step::Confirm => "confirm",
        }
    }

    pub fn question(self) -> &'static str {
        match self {
            Step::Scope => "Where do you want to install?",
            Step::Remote => "Which machine? (user@host)",
            Step::Mountpoint => "Where is the target mounted?",
            Step::Hostname => "What should the machine be called?",
            Step::User => "What is your username?",
            Step::Password => "Set a login password",
            Step::PasswordConfirm => "Type the password again",
            Step::Role => "What kind of system is this?",
            Step::Ssh => "Enable the SSH server?",
            Step::Locale => "Where in the world are you?",
            Step::Filesystem => "Which filesystem?",
            Step::Encrypt => "Encrypt the disk?",
            Step::StorageMode => "How should storage be laid out?",
            Step::Lvm => "Use LVM?",
            Step::Disks => "Which disk(s) to install to?",
            Step::Efi => "EFI boot partition size?",
            Step::Storage => "Pools and volumes (LVM)",
            Step::ExtraDisks => "Configure the remaining disks?",
            Step::Pools => "Volume groups (LVM pools)",
            Step::Volumes => "Logical volumes",
            Step::DocSubvols => "btrfs subvolumes under /doc",
            Step::Overwrite => "Existing data on the disk?",
            Step::NetworkCleanup => "Clean up competing network routes?",
            Step::BinEnsure => "Provision extra binaries after install?",
            Step::Dotfiles => "Dotfiles repository (optional)",
            Step::Review => "Review the plan",
            Step::Confirm => "Confirm — this will erase the disk",
        }
    }

    pub fn help(self) -> &'static str {
        match self {
            Step::Scope => "Local installs onto this machine; remote installs over SSH.",
            Step::Remote => "The target must be reachable over SSH with key auth.",
            Step::Mountpoint => "Where the new root is mounted during install (usually /mnt).",
            Step::Hostname => "Lowercase letters, digits and dashes.",
            Step::User => "Your primary account; gets sudo.",
            Step::Password => "Leave blank for a password-less account. Hidden as you type.",
            Step::PasswordConfirm => "Must match the password you just entered.",
            Step::Role => "Laptop adds a desktop; server is headless.",
            Step::Ssh => "Turn on the OpenSSH daemon at boot.",
            Step::Locale => "Sets the system timezone and clock.",
            Step::Filesystem => "btrfs supports subvolumes and snapshots; ext4 is simpler.",
            Step::Encrypt => "Full-disk encryption (LUKS), passphrase at boot.",
            Step::StorageMode => {
                "single-disk / joined-lvm are supported; the rest are experimental."
            }
            Step::Lvm => "LVM pools one or more disks into flexible volumes; plain uses a single disk.",
            Step::Disks => "space toggles a disk · every partition on selected disks is erased.",
            Step::Efi => "The ESP holds the bootloader, mounted at /boot/efi.",
            Step::Storage => "←→ pool/volumes · ↑↓ select · −/+ resize · a add · d delete · r rename · m manual.",
            Step::ExtraDisks => "Disks not used by the install — set a mount for each, or skip. Boot media is ignored.",
            Step::Pools => "One LVM volume group per pool. type rename · ^n add · ^x remove.",
            Step::Volumes => "↑↓ vol · ←→ field · space cycle · type edit · +/- size · ^n/^x.",
            Step::DocSubvols => "Subvolumes carved under /doc. type edit · ^n add · ^x remove.",
            Step::Overwrite => "Allow wiping an existing LVM volume group if one is present.",
            Step::NetworkCleanup => {
                "Remove extra default routes that can break the remote SSH link."
            }
            Step::BinEnsure => "Run the `bin` provisioner in the installed system (needs a token).",
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
            | Step::Locale
            | Step::Lvm
            | Step::Filesystem
            | Step::Encrypt
            | Step::StorageMode
            | Step::Efi
            | Step::Overwrite
            | Step::NetworkCleanup
            | Step::BinEnsure => StepKind::Choice,
            Step::Remote | Step::Mountpoint | Step::Hostname | Step::User | Step::Dotfiles => {
                StepKind::Text
            }
            Step::Password | Step::PasswordConfirm => StepKind::Password,
            Step::Disks => StepKind::DiskSelect,
            Step::ExtraDisks => StepKind::ExtraDisks,
            Step::Storage => StepKind::Editor(Editor::Disks),
            Step::Pools => StepKind::Editor(Editor::Pools),
            Step::Volumes => StepKind::Editor(Editor::Volumes),
            Step::DocSubvols => StepKind::Editor(Editor::DocSubvols),
            Step::Review => StepKind::Review,
            Step::Confirm => StepKind::Confirm,
        }
    }
}

/// Curated timezone list for the locale step: (tz id, place, latitude, longitude).
/// The coordinates orient the globe and place the location pin.
pub const TIMEZONES: &[(&str, &str, f32, f32)] = &[
    ("UTC", "coordinated universal time", 0.0, 0.0),
    ("Europe/Amsterdam", "Netherlands", 52.37, 4.90),
    ("Europe/London", "United Kingdom", 51.51, -0.13),
    ("Europe/Berlin", "Germany", 52.52, 13.40),
    ("Europe/Tirane", "Albania", 41.33, 19.82),
    ("Europe/Belgrade", "Serbia / Balkans", 44.79, 20.45),
    ("Europe/Moscow", "Russia (west)", 55.75, 37.62),
    ("America/New_York", "US East", 40.71, -74.01),
    ("America/Chicago", "US Central", 41.88, -87.63),
    ("America/Los_Angeles", "US West", 34.05, -118.24),
    ("America/Sao_Paulo", "Brazil", -23.55, -46.63),
    ("Africa/Cairo", "Egypt", 30.04, 31.24),
    ("Asia/Dubai", "UAE / Gulf", 25.20, 55.27),
    ("Asia/Kolkata", "India", 28.61, 77.21),
    ("Asia/Shanghai", "China", 31.23, 121.47),
    ("Asia/Tokyo", "Japan", 35.68, 139.69),
    ("Australia/Sydney", "Australia (east)", -33.87, 151.21),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepKind {
    Choice,
    Text,
    Password,
    /// Multi-select (LVM) or single-select disk picker with checkboxes.
    DiskSelect,
    /// Per-disk mount configuration for disks not used by the install.
    ExtraDisks,
    Editor(Editor),
    Review,
    Confirm,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Editor {
    Disks,
    Pools,
    Volumes,
    DocSubvols,
}

impl Editor {
    pub fn field_count(self) -> usize {
        match self {
            Editor::Disks => 4,   // role, pool, path, size
            Editor::Volumes => 4, // name, mount, pool, size
            Editor::Pools | Editor::DocSubvols => 1,
        }
    }

    pub fn field_name(self, field: usize) -> &'static str {
        match (self, field) {
            (Editor::Disks, 0) => "role",
            (Editor::Disks, 1) => "pool",
            (Editor::Disks, 2) => "path",
            (Editor::Disks, _) => "size",
            (Editor::Volumes, 0) => "name",
            (Editor::Volumes, 1) => "mount",
            (Editor::Volumes, 2) => "pool",
            (Editor::Volumes, _) => "size",
            (Editor::Pools, _) => "name",
            (Editor::DocSubvols, _) => "name",
        }
    }

    /// Whether the field is edited as free text (buffer-backed) vs cycled/adjusted.
    pub fn is_text(self, field: usize) -> bool {
        match self {
            Editor::Disks => matches!(field, 2 | 3),       // path, size
            Editor::Volumes => matches!(field, 0 | 1 | 3), // name, mount, size
            Editor::Pools | Editor::DocSubvols => true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opt {
    pub label: String,
    pub desc: String,
}

/// The target connection is deliberately separate from install execution: a
/// remote target is contacted as soon as the address is accepted, not lazily
/// when the disk page happens to open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkState {
    Offline,
    Linking,
    Connected,
    Unreachable(String),
    Local,
}

enum LinkUpdate {
    Connected(TargetFacts),
    Unreachable(String),
}

impl Opt {
    fn new(label: &str, desc: &str) -> Self {
        Self {
            label: label.to_string(),
            desc: desc.to_string(),
        }
    }
}

/// Which panel of the disk-stage pool/volume editor is focused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskPane {
    Pools,
    Volumes,
}

pub struct Flow {
    pub state: InstallState,
    pub pos: usize,
    /// Highlighted option for Choice steps.
    pub cursor: usize,
    /// Editor item / field cursors.
    pub item: usize,
    pub field: usize,
    /// Working text buffer (Text/Password steps and the focused editor text field).
    pub buffer: String,
    /// Cursor-aware text state supplied by `tui-input`; `buffer` remains the
    /// serializable/editable value consumed by the installer model.
    text_input: Input,
    pub confirm_input: String,
    pub password: String,
    pub password_confirm: String,
    pub status: String,
    pub preflight: Option<PreflightReport>,
    pub facts: Option<TargetFacts>,
    pub disk_error: Option<String>,
    pub link: LinkState,
    link_rx: Option<Receiver<LinkUpdate>>,
    /// Advanced disk/pool/volume editors are entered deliberately from the
    /// disk stage or the multi-disk layout choice.
    pub manual_storage: bool,
    /// Disk-stage editor: which panel is focused and the selection in each.
    pub disk_pane: DiskPane,
    pub pool_sel: usize,
    pub vol_sel: usize,
    /// When renaming a pool/volume in the storage editor, the in-progress name.
    pub disk_rename: Option<String>,
    /// Disk paths selected for the install (multi for LVM, one for plain).
    pub disk_selected: BTreeSet<String>,
    /// Cursor + mount-edit state for the extra-disks step.
    pub extra_sel: usize,
    pub extra_edit: Option<String>,
    pub done: bool,
    pub quit: bool,
    /// Test hook: skip the (impure) facts probe when entering the disk editor.
    pub disable_discovery: bool,
}

impl Flow {
    pub fn new(state: InstallState) -> Self {
        let mut flow = Self {
            state,
            pos: 0,
            cursor: 0,
            item: 0,
            field: 0,
            buffer: String::new(),
            text_input: Input::default(),
            confirm_input: String::new(),
            password: String::new(),
            password_confirm: String::new(),
            status: String::new(),
            preflight: None,
            facts: None,
            disk_error: None,
            link: LinkState::Offline,
            link_rx: None,
            manual_storage: false,
            disk_pane: DiskPane::Pools,
            pool_sel: 0,
            vol_sel: 0,
            disk_rename: None,
            disk_selected: BTreeSet::new(),
            extra_sel: 0,
            extra_edit: None,
            done: false,
            quit: false,
            disable_discovery: false,
        };
        flow.load();
        flow
    }

    pub fn steps(&self) -> Vec<Step> {
        let mut steps = vec![Step::Scope];
        match self.state.scope {
            InstallScope::Remote => steps.push(Step::Remote),
            InstallScope::Local => steps.push(Step::Mountpoint),
        }
        // Machine identity + locale first.
        steps.extend([Step::Locale, Step::Hostname, Step::Role, Step::Ssh]);

        // Storage: decide the TYPE first (LVM? then LUKS? then filesystem), THEN
        // which disk(s), then boot, then the layout.
        steps.extend([Step::Lvm, Step::Encrypt, Step::Filesystem, Step::Disks]);
        steps.push(Step::Efi);
        if self.state.use_lvm {
            steps.push(Step::Storage);
        }
        // btrfs → subvolumes.
        if self.state.filesystem == Filesystem::Btrfs {
            steps.push(Step::DocSubvols);
        }
        steps.push(Step::Overwrite);
        // Remaining disks (not the install target, not boot media) → mounts.
        if !self.extra_disks().is_empty() {
            steps.push(Step::ExtraDisks);
        }

        // System extras.
        steps.extend([Step::NetworkCleanup, Step::BinEnsure, Step::Dotfiles]);

        // User account at the very end (after everything about the machine).
        steps.extend([Step::User, Step::Password, Step::PasswordConfirm]);

        steps.extend([Step::Review, Step::Confirm]);
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
        self.steps().get(self.pos + 1).copied()
    }

    pub fn step_number(&self) -> (usize, usize) {
        (self.pos + 1, self.steps().len())
    }

    // ── choice options ──────────────────────────────────────────

    pub fn options(&self) -> Vec<Opt> {
        match self.current() {
            Step::Locale => TIMEZONES
                .iter()
                .map(|(tz, place, _, _)| Opt::new(tz, place))
                .collect(),
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
            Step::Lvm => vec![
                Opt::new("LVM", "pool one or more disks into flexible volumes"),
                Opt::new("plain", "one disk, a single root partition"),
            ],
            Step::Encrypt => vec![
                Opt::new("no", "no disk encryption"),
                Opt::new("yes", "LUKS full-disk encryption"),
            ],
            Step::StorageMode => vec![
                Opt::new(
                    "use selected disk",
                    "erase one selected disk into one LVM pool",
                ),
                Opt::new(
                    "combine all disks",
                    "one LVM pool spanning every selected disk",
                ),
                Opt::new("one pool per disk", "keep selected disks as separate pools"),
                Opt::new("manual", "open the detailed disk, pool, and volume editors"),
            ],
            Step::Overwrite => vec![
                Opt::new("keep", "fail if an existing pool is present"),
                Opt::new("wipe", "remove any existing LVM volume group"),
            ],
            Step::NetworkCleanup => vec![
                Opt::new("yes", "drop competing default routes"),
                Opt::new("no", "leave routing untouched"),
            ],
            Step::BinEnsure => vec![
                Opt::new("skip", "do not run the bin provisioner"),
                Opt::new("run", "run bin ensure in the installed system"),
            ],
            Step::Disks => self
                .disk_choices()
                .iter()
                .map(|disk| {
                    let contents = self
                        .facts
                        .as_ref()
                        .and_then(|f| f.disks.iter().find(|d| d.path == disk.path))
                        .map(|d| d.content_summary())
                        .unwrap_or_else(|| "unknown".to_string());
                    Opt::new(
                        &disk.path,
                        &format!(
                            "{}G · {} · {}",
                            disk.size_gib,
                            disk.model.as_deref().unwrap_or("disk"),
                            contents
                        ),
                    )
                })
                .collect(),
            Step::Efi => vec![
                Opt::new("512 MiB", "minimal ESP"),
                Opt::new("1 GiB", "recommended — room for multiple kernels"),
                Opt::new("2 GiB", "generous"),
            ],
            _ => Vec::new(),
        }
    }

    /// Detected disks (or the current selection) for the disk picker.
    fn disk_choices(&self) -> Vec<DiskChoice> {
        if !self.state.discovered_disks.is_empty() {
            self.state.discovered_disks.clone()
        } else {
            self.state.disks.clone()
        }
    }

    // ── disk selection (multi-select) ────────────────────────────

    /// Disks that can be installed to / mounted — excludes the live boot media.
    pub fn installable_disks(&self) -> Vec<DiskChoice> {
        if let Some(facts) = &self.facts {
            facts
                .disks
                .iter()
                .filter(|d| !d.is_boot_media())
                .map(|d| DiskChoice {
                    path: d.path.clone(),
                    size_gib: d.size_bytes / (1024 * 1024 * 1024),
                    model: d.model.clone(),
                })
                .collect()
        } else {
            self.disk_choices()
        }
    }

    /// Content summary for a disk path from the facts probe.
    pub fn disk_contents(&self, path: &str) -> String {
        self.facts
            .as_ref()
            .and_then(|f| f.disks.iter().find(|d| d.path == path))
            .map(|d| d.content_summary())
            .unwrap_or_else(|| "unknown".to_string())
    }

    pub fn is_disk_selected(&self, path: &str) -> bool {
        self.disk_selected.contains(path)
    }

    /// Toggle a disk in the install set. For plain (no LVM) only one may be
    /// selected, so toggling one clears the rest.
    pub fn disk_toggle(&mut self, path: &str) {
        if self.disk_selected.contains(path) {
            self.disk_selected.remove(path);
        } else {
            if !self.state.use_lvm {
                self.disk_selected.clear();
            }
            self.disk_selected.insert(path.to_string());
        }
    }

    /// Disks detected but NOT chosen for the install (and not boot media) — the
    /// candidates for extra data mounts.
    pub fn extra_disks(&self) -> Vec<DiskChoice> {
        self.installable_disks()
            .into_iter()
            .filter(|d| !self.disk_selected.contains(&d.path))
            .collect()
    }

    // ── extra data-disk mounts ───────────────────────────────────

    pub fn extra_mount_of(&self, path: &str) -> Option<&str> {
        self.state.data_mounts.get(path).map(String::as_str)
    }

    pub fn extra_begin_edit(&mut self) {
        if let Some(disk) = self.extra_disks().get(self.extra_sel) {
            let current = self
                .state
                .data_mounts
                .get(&disk.path)
                .cloned()
                .unwrap_or_else(|| "/mnt/data".to_string());
            self.extra_edit = Some(current);
        }
    }

    pub fn extra_edit_insert(&mut self, ch: char) {
        if let Some(buf) = self.extra_edit.as_mut() {
            if !ch.is_control() && !ch.is_whitespace() {
                buf.push(ch);
            }
        }
    }

    pub fn extra_edit_backspace(&mut self) {
        if let Some(buf) = self.extra_edit.as_mut() {
            buf.pop();
        }
    }

    pub fn extra_apply_edit(&mut self) {
        let Some(buf) = self.extra_edit.take() else {
            return;
        };
        let buf = buf.trim().to_string();
        if let Some(disk) = self.extra_disks().get(self.extra_sel).cloned() {
            if buf.is_empty() || !buf.starts_with('/') {
                self.state.data_mounts.remove(&disk.path);
            } else {
                self.state.data_mounts.insert(disk.path, buf);
            }
        }
    }

    pub fn extra_cancel_edit(&mut self) {
        self.extra_edit = None;
    }

    pub fn extra_clear(&mut self) {
        if let Some(disk) = self.extra_disks().get(self.extra_sel).cloned() {
            self.state.data_mounts.remove(&disk.path);
        }
    }

    pub fn extra_sel_next(&mut self) {
        let n = self.extra_disks().len();
        if n > 0 {
            self.extra_sel = (self.extra_sel + 1) % n;
        }
    }

    pub fn extra_sel_prev(&mut self) {
        let n = self.extra_disks().len();
        if n > 0 {
            self.extra_sel = (self.extra_sel + n - 1) % n;
        }
    }

    /// Commit the multi-selected disks into the install layout (one pool across
    /// all of them for LVM; a single disk for plain).
    fn apply_disk_selection(&mut self) {
        let selected: Vec<DiskChoice> = self
            .installable_disks()
            .into_iter()
            .filter(|d| self.disk_selected.contains(&d.path))
            .collect();
        self.state.disks = selected.clone();
        self.state.disk_roles.clear();
        self.state.disk_volume_groups.clear();
        for disk in &selected {
            self.state
                .disk_roles
                .insert(disk.path.clone(), DiskRole::System);
            self.state
                .disk_volume_groups
                .insert(disk.path.clone(), DEFAULT_STORAGE_POOL_NAME.to_string());
        }
        self.state.normalize_disk_roles();
        self.state.normalize_storage_assignments();
        self.state.fit_volumes_to_disk();
    }

    /// (latitude, longitude) of the currently highlighted timezone, for the
    /// globe on the locale step.
    pub fn locale_coords(&self) -> (f32, f32) {
        TIMEZONES
            .get(self.cursor)
            .map(|(_, _, lat, lon)| (*lat, *lon))
            .unwrap_or((0.0, 0.0))
    }

    // ── editor accessors ────────────────────────────────────────

    pub fn editor(&self) -> Option<Editor> {
        match self.current().kind() {
            StepKind::Editor(editor) => Some(editor),
            _ => None,
        }
    }

    pub fn item_count(&self) -> usize {
        match self.editor() {
            Some(Editor::Disks) => self.state.disks.len(),
            Some(Editor::Pools) => self.state.volume_groups.len(),
            Some(Editor::Volumes) => self.state.volumes.len(),
            Some(Editor::DocSubvols) => self.state.doc_subvolumes.len(),
            None => 0,
        }
    }

    fn pool_names(&self) -> Vec<String> {
        self.state
            .volume_groups
            .iter()
            .map(|g| g.name.clone())
            .collect()
    }

    // ── disk-stage pool/volume editor ────────────────────────────

    pub fn pool_count(&self) -> usize {
        self.state.volume_groups.len()
    }

    pub fn selected_pool_name(&self) -> Option<String> {
        self.state
            .volume_groups
            .get(self.pool_sel)
            .map(|g| g.name.clone())
    }

    /// Indices into `state.volumes` for volumes assigned to the selected pool.
    pub fn volumes_in_selected_pool(&self) -> Vec<usize> {
        let Some(pool) = self.selected_pool_name() else {
            return Vec::new();
        };
        self.state
            .volumes
            .iter()
            .enumerate()
            .filter(|(_, v)| self.state.volume_group_for_volume(&v.name) == pool)
            .map(|(i, _)| i)
            .collect()
    }

    pub fn pool_capacity_gib(&self, pool: &str) -> u64 {
        let assigned: u64 = self
            .state
            .disks
            .iter()
            .filter(|d| self.state.disk_volume_group_for_path(&d.path) == Some(pool))
            .map(|d| d.size_gib)
            .sum();
        if assigned > 0 {
            assigned
        } else {
            self.state.total_disk_gib()
        }
    }

    pub fn pool_used_gib(&self, pool: &str) -> u64 {
        self.state
            .volumes
            .iter()
            .filter(|v| self.state.volume_group_for_volume(&v.name) == pool)
            .map(|v| v.size_gib)
            .sum()
    }

    pub fn disk_focus_pools(&mut self) {
        self.disk_pane = DiskPane::Pools;
    }

    pub fn disk_focus_volumes(&mut self) {
        if !self.volumes_in_selected_pool().is_empty() {
            self.disk_pane = DiskPane::Volumes;
            self.vol_sel = 0;
        }
    }

    pub fn disk_sel_next(&mut self) {
        match self.disk_pane {
            DiskPane::Pools => {
                let n = self.pool_count();
                if n > 0 {
                    self.pool_sel = (self.pool_sel + 1) % n;
                    self.vol_sel = 0;
                }
            }
            DiskPane::Volumes => {
                let n = self.volumes_in_selected_pool().len();
                if n > 0 {
                    self.vol_sel = (self.vol_sel + 1) % n;
                }
            }
        }
    }

    pub fn disk_sel_prev(&mut self) {
        match self.disk_pane {
            DiskPane::Pools => {
                let n = self.pool_count();
                if n > 0 {
                    self.pool_sel = (self.pool_sel + n - 1) % n;
                    self.vol_sel = 0;
                }
            }
            DiskPane::Volumes => {
                let n = self.volumes_in_selected_pool().len();
                if n > 0 {
                    self.vol_sel = (self.vol_sel + n - 1) % n;
                }
            }
        }
    }

    fn selected_volume_index(&self) -> Option<usize> {
        self.volumes_in_selected_pool().get(self.vol_sel).copied()
    }

    /// Resize the selected volume by `delta` GiB, taking the change from the
    /// pool's fill volume (`home`, else the largest other) so the pool stays
    /// balanced — like dragging a partition boundary.
    pub fn disk_resize(&mut self, delta: i64) {
        if self.disk_pane != DiskPane::Volumes {
            return;
        }
        let Some(i) = self.selected_volume_index() else {
            return;
        };
        let cur = self.state.volumes[i].size_gib as i64;
        let new = (cur + delta).max(1) as u64;
        let applied = new as i64 - cur;
        let members = self.volumes_in_selected_pool();
        let fill = members
            .iter()
            .copied()
            .filter(|&j| j != i)
            .find(|&j| self.state.volumes[j].name == "home")
            .or_else(|| {
                members
                    .iter()
                    .copied()
                    .filter(|&j| j != i)
                    .max_by_key(|&j| self.state.volumes[j].size_gib)
            });
        self.state.volumes[i].size_gib = new;
        if let Some(f) = fill {
            let fv = self.state.volumes[f].size_gib as i64;
            self.state.volumes[f].size_gib = (fv - applied).max(1) as u64;
        }
    }

    pub fn disk_add(&mut self) {
        match self.disk_pane {
            DiskPane::Pools => {
                let name = unique_name("pool", &self.pool_names());
                self.state.volume_groups.push(VolumeGroupDraft { name });
                self.pool_sel = self.state.volume_groups.len() - 1;
                self.vol_sel = 0;
            }
            DiskPane::Volumes => {
                let pool = self
                    .selected_pool_name()
                    .unwrap_or_else(|| DEFAULT_STORAGE_POOL_NAME.to_string());
                let name = unique_name(
                    "vol",
                    &self.state.volumes.iter().map(|v| v.name.clone()).collect::<Vec<_>>(),
                );
                self.state.volumes.push(Volume {
                    name: name.clone(),
                    mountpoint: Mountpoint::Path(format!("/{name}")),
                    size_gib: 16,
                });
                self.state.set_volume_group_for_volume(&name, &pool);
                self.vol_sel = self.volumes_in_selected_pool().len().saturating_sub(1);
            }
        }
    }

    pub fn disk_delete(&mut self) {
        match self.disk_pane {
            DiskPane::Pools => {
                if self.state.volume_groups.len() > 1 {
                    self.state.volume_groups.remove(self.pool_sel);
                    self.state.normalize_storage_assignments();
                    self.pool_sel = self.pool_sel.min(self.pool_count().saturating_sub(1));
                } else {
                    self.status = "keep at least one pool".to_string();
                }
            }
            DiskPane::Volumes => {
                if let Some(i) = self.selected_volume_index() {
                    let name = self.state.volumes[i].name.clone();
                    self.state.volumes.remove(i);
                    self.state.volume_volume_groups.remove(&name);
                    self.vol_sel = self.vol_sel.saturating_sub(1);
                }
            }
        }
    }

    // ── rename the selected pool / volume ────────────────────────

    pub fn disk_begin_rename(&mut self) {
        let current = match self.disk_pane {
            DiskPane::Pools => self.selected_pool_name(),
            DiskPane::Volumes => self
                .selected_volume_index()
                .map(|i| self.state.volumes[i].name.clone()),
        };
        if let Some(name) = current {
            self.disk_rename = Some(name);
        }
    }

    pub fn disk_rename_insert(&mut self, ch: char) {
        if let Some(name) = self.disk_rename.as_mut() {
            if !ch.is_control() && !ch.is_whitespace() {
                name.push(ch);
            }
        }
    }

    pub fn disk_rename_backspace(&mut self) {
        if let Some(name) = self.disk_rename.as_mut() {
            name.pop();
        }
    }

    pub fn disk_cancel_rename(&mut self) {
        self.disk_rename = None;
    }

    pub fn disk_apply_rename(&mut self) {
        let Some(new) = self.disk_rename.take() else {
            return;
        };
        let new = new.trim().to_string();
        if new.is_empty() {
            return;
        }
        match self.disk_pane {
            DiskPane::Pools => {
                if let Some(old) = self.selected_pool_name() {
                    if old != new {
                        let _ = self.state.rename_volume_group(&old, &new);
                    }
                }
            }
            DiskPane::Volumes => {
                if let Some(i) = self.selected_volume_index() {
                    let old = self.state.volumes[i].name.clone();
                    if old != new {
                        self.rename_volume(&old, &new);
                    }
                }
            }
        }
    }

    // ── navigation & load ───────────────────────────────────────

    fn load(&mut self) {
        self.cursor = 0;
        self.item = 0;
        self.field = 0;
        self.buffer.clear();
        self.disk_error = None;
        match self.current() {
            Step::Scope => self.cursor = usize::from(self.state.scope == InstallScope::Remote),
            Step::Role => self.cursor = usize::from(self.state.role == InstallRole::Server),
            Step::Ssh => self.cursor = usize::from(self.state.allow_ssh),
            Step::Locale => {
                self.cursor = TIMEZONES
                    .iter()
                    .position(|(tz, _, _, _)| *tz == self.state.timezone)
                    .unwrap_or(0)
            }
            Step::Filesystem => {
                self.cursor = usize::from(self.state.filesystem == Filesystem::Ext4)
            }
            Step::Encrypt => self.cursor = usize::from(self.state.encrypt),
            Step::Overwrite => self.cursor = usize::from(self.state.overwrite_existing_storage),
            Step::NetworkCleanup => self.cursor = usize::from(!self.state.network_route_cleanup),
            Step::BinEnsure => self.cursor = usize::from(!self.state.skip_bin_ensure),
            Step::StorageMode => {
                self.cursor = if self.manual_storage {
                    3
                } else {
                    match self.state.storage_mode {
                        StorageMode::SingleDisk => 0,
                        StorageMode::JoinedLvm => 1,
                        StorageMode::SeparatePools => 2,
                        StorageMode::Manual => 3,
                    }
                }
            }
            Step::Remote => self.buffer = self.state.remote.clone(),
            Step::Mountpoint => self.buffer = self.state.mountpoint.clone(),
            Step::Hostname => self.buffer = self.state.hostname.clone(),
            Step::User => self.buffer = self.state.install_user.clone(),
            Step::Dotfiles => self.buffer = self.state.dotfiles_repo.clone().unwrap_or_default(),
            Step::Lvm => self.cursor = usize::from(!self.state.use_lvm),
            Step::Disks => {
                // Multi-select disk picker: discover, seed the selection.
                self.discover_disks();
                if self.disk_selected.is_empty() {
                    for disk in self.state.disks.iter() {
                        self.disk_selected.insert(disk.path.clone());
                    }
                    // Default to the first installable disk if nothing chosen yet.
                    if self.disk_selected.is_empty() {
                        if let Some(first) = self.installable_disks().first() {
                            self.disk_selected.insert(first.path.clone());
                        }
                    }
                }
                self.cursor = 0;
            }
            Step::ExtraDisks => {
                self.extra_sel = 0;
                self.extra_edit = None;
            }
            Step::Efi => {
                self.cursor = match self.state.esp_size_mib {
                    0..=512 => 0,
                    513..=1024 => 1,
                    _ => 2,
                }
            }
            Step::Storage => {
                // Facts are already cached from the disk picker; just balance.
                if !self.manual_storage {
                    self.state.fit_volumes_to_disk();
                }
                self.pool_sel = self.pool_sel.min(self.pool_count().saturating_sub(1));
                self.disk_pane = DiskPane::Pools;
            }
            Step::Pools | Step::Volumes | Step::DocSubvols => self.sync_buffer(),
            _ => {}
        }
        self.sync_text_input();
    }

    /// Load the focused editor text field into the buffer.
    fn sync_buffer(&mut self) {
        self.buffer = self.editor_text_value().unwrap_or_default();
        self.sync_text_input();
    }

    fn sync_text_input(&mut self) {
        self.text_input = Input::new(self.buffer.clone());
    }

    fn edit_text(&mut self, request: InputRequest) {
        // Tests and callers may set the public buffer directly. Reconcile it
        // before asking tui-input to preserve cursor-aware editing.
        if self.text_input.to_string() != self.buffer {
            self.sync_text_input();
        }
        self.text_input.handle(request);
        self.buffer = self.text_input.to_string();
    }

    pub fn text_cursor(&self) -> usize {
        self.text_input.cursor()
    }

    pub fn text_cursor_prev(&mut self) {
        self.edit_text(InputRequest::GoToPrevChar);
    }

    pub fn text_cursor_next(&mut self) {
        self.edit_text(InputRequest::GoToNextChar);
    }

    fn discover_disks(&mut self) {
        if self.disable_discovery {
            return;
        }
        if self.facts.is_some() {
            return;
        }
        if self.state.scope == InstallScope::Remote {
            // The worker owns remote collection. Never stall the UI here.
            return;
        }
        let facts = crate::facts::collect();
        self.accept_facts(facts);
    }

    fn accept_facts(&mut self, facts: TargetFacts) {
        let first_facts = self.facts.is_none();
        // Merge discovered disks into the working set (new ones start Ignored).
        self.state.discovered_disks = crate::facts::disk_choices(&facts);
        for disk in crate::facts::disk_choices(&facts) {
            if !self.state.disks.iter().any(|d| d.path == disk.path) {
                self.state
                    .disk_roles
                    .entry(disk.path.clone())
                    .or_insert(DiskRole::Ignore);
                self.state.disks.push(disk);
            }
        }
        self.state.normalize_disk_roles();
        if first_facts {
            self.apply_intelligent_defaults(&facts);
        }
        self.facts = Some(facts);
    }

    fn apply_intelligent_defaults(&mut self, facts: &TargetFacts) {
        let mut candidates = facts.disks.iter().collect::<Vec<_>>();
        candidates.sort_by_key(|disk| std::cmp::Reverse(disk.size_bytes));
        let selected = candidates
            .iter()
            // Do not silently target the currently-mounted system disk. Prefer
            // a truly empty device, then an unmounted one; otherwise require a
            // deliberate user choice in the disk editor.
            .find(|disk| disk.partitions.is_empty())
            .or_else(|| {
                candidates.iter().find(|disk| {
                    disk.partitions
                        .iter()
                        .all(|partition| partition.mountpoints.is_empty())
                })
            })
            .copied();
        if let Some(disk) = selected {
            self.state.disks = crate::facts::disk_choices(facts)
                .into_iter()
                .filter(|choice| choice.path == disk.path)
                .collect();
            self.state.disk_roles.clear();
            self.state
                .disk_roles
                .insert(disk.path.clone(), DiskRole::System);
            self.state.normalize_disk_roles();
        }
        if facts.disks.len() <= 1 {
            self.state.storage_mode = StorageMode::SingleDisk;
        }
        if let Some(mem_mib) = facts.mem_mib {
            let swap_gib = (mem_mib / 1024).clamp(1, 64);
            if let Some(swap) = self
                .state
                .volumes
                .iter_mut()
                .find(|volume| matches!(volume.mountpoint, Mountpoint::Swap))
            {
                swap.size_gib = swap_gib;
            }
        }
    }


    /// Drain the background remote probe. Called by the event loop before every
    /// frame, so the header and disk page update without a blocking transition.
    pub fn poll_link(&mut self) {
        let Some(rx) = &self.link_rx else { return };
        let update = match rx.try_recv() {
            Ok(update) => update,
            Err(TryRecvError::Empty) => return,
            Err(TryRecvError::Disconnected) => {
                self.link_rx = None;
                self.link = LinkState::Unreachable("probe worker stopped".to_string());
                return;
            }
        };
        self.link_rx = None;
        match update {
            LinkUpdate::Connected(facts) => {
                self.link = LinkState::Connected;
                self.disk_error = None;
                self.accept_facts(facts);
            }
            LinkUpdate::Unreachable(err) => {
                self.link = LinkState::Unreachable(err.clone());
                self.disk_error = Some(err);
            }
        }
    }

    fn begin_remote_probe(&mut self) {
        let remote = self.state.remote.clone();
        self.link = LinkState::Linking;
        self.facts = None;
        self.disk_error = None;
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let update = match crate::facts::collect_over_ssh(&remote) {
                Ok(facts) => LinkUpdate::Connected(facts),
                Err(err) => LinkUpdate::Unreachable(err),
            };
            let _ = tx.send(update);
        });
        self.link_rx = Some(rx);
    }

    pub fn link_badge(&self) -> (&'static str, &'static str, ratatui::style::Color) {
        match &self.link {
            LinkState::Local => ("●", "this machine", crate::install::theme::GREEN),
            LinkState::Offline => ("○", "offline", crate::install::theme::MUTED),
            LinkState::Linking => ("◐", "linking…", crate::install::theme::YELLOW),
            LinkState::Connected => ("●", "connected", crate::install::theme::GREEN),
            LinkState::Unreachable(_) => ("✗", "unreachable", crate::install::theme::RED),
        }
    }

    // ── input: choices ──────────────────────────────────────────

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

    // ── input: editors ──────────────────────────────────────────

    pub fn item_next(&mut self) {
        self.flush_editor();
        let count = self.item_count();
        if count > 0 {
            self.item = (self.item + 1) % count;
        }
        self.sync_buffer();
    }

    pub fn item_prev(&mut self) {
        self.flush_editor();
        let count = self.item_count();
        if count > 0 {
            self.item = (self.item + count - 1) % count;
        }
        self.sync_buffer();
    }

    pub fn field_next(&mut self) {
        self.flush_editor();
        if let Some(editor) = self.editor() {
            self.field = (self.field + 1) % editor.field_count();
        }
        self.sync_buffer();
    }

    pub fn field_prev(&mut self) {
        self.flush_editor();
        if let Some(editor) = self.editor() {
            let n = editor.field_count();
            self.field = (self.field + n - 1) % n;
        }
        self.sync_buffer();
    }

    /// Space: cycle the enum-valued field (role/pool/mount kind).
    pub fn cycle(&mut self) {
        let Some(editor) = self.editor() else { return };
        match (editor, self.field) {
            (Editor::Disks, 0) => {
                // role
                if let Some(disk) = self.state.disks.get(self.item).cloned() {
                    let role = self.state.disk_role_for_path(&disk.path).next();
                    self.state.set_disk_role(&disk.path, role);
                    self.state.normalize_disk_roles();
                }
            }
            (Editor::Disks, 1) => {
                if let Some(disk) = self.state.disks.get(self.item).cloned() {
                    let pools = self.pool_names();
                    let current = self
                        .state
                        .disk_volume_group_for_path(&disk.path)
                        .map(str::to_string);
                    if let Some(next) = cycle_pool(&pools, current.as_deref()) {
                        self.state.set_disk_volume_group(&disk.path, &next);
                    }
                }
            }
            (Editor::Volumes, 1) => {
                // mount: toggle Path <-> Swap
                if let Some(vol) = self.state.volumes.get_mut(self.item) {
                    vol.mountpoint = match &vol.mountpoint {
                        Mountpoint::Swap => Mountpoint::Path("/".to_string()),
                        Mountpoint::Path(_) => Mountpoint::Swap,
                    };
                }
                self.sync_buffer();
            }
            (Editor::Volumes, 2) => {
                if let Some(vol) = self.state.volumes.get(self.item).cloned() {
                    let pools = self.pool_names();
                    let current = self.state.volume_group_for_volume(&vol.name).to_string();
                    if let Some(next) = cycle_pool(&pools, Some(&current)) {
                        self.state.set_volume_group_for_volume(&vol.name, &next);
                    }
                }
            }
            _ => {}
        }
    }

    /// +/- on a numeric field.
    pub fn adjust(&mut self, delta: i64) {
        let Some(editor) = self.editor() else { return };
        match (editor, self.field) {
            (Editor::Disks, 3) => {
                if let Some(disk) = self.state.disks.get_mut(self.item) {
                    disk.size_gib = apply_delta(disk.size_gib, delta);
                }
                self.sync_buffer();
            }
            (Editor::Volumes, 3) => {
                if let Some(vol) = self.state.volumes.get_mut(self.item) {
                    vol.size_gib = apply_delta(vol.size_gib, delta);
                }
                self.sync_buffer();
            }
            _ => {}
        }
    }

    /// Fit the current logical-volume plan into the selected disks without
    /// deleting mounts. This is an explicit recovery action, never an implicit
    /// destructive rewrite of a user-edited layout.
    pub fn scale_to_fit(&mut self) {
        let capacity = self.state.total_disk_gib();
        let used = self.state.used_gib();
        if capacity == 0 {
            self.status = "select a disk before scaling volumes".to_string();
            return;
        }
        let mut excess = used.saturating_sub(capacity);
        if excess == 0 {
            self.status = "layout already fits selected capacity".to_string();
            return;
        }
        while excess > 0 {
            let Some((index, _)) = self
                .state
                .volumes
                .iter()
                .enumerate()
                .filter(|(_, volume)| volume.size_gib > 1)
                .max_by_key(|(_, volume)| volume.size_gib)
            else {
                self.status = "cannot scale layout further without removing a volume".to_string();
                return;
            };
            let volume = &mut self.state.volumes[index];
            let reduction = excess.min(volume.size_gib - 1);
            volume.size_gib -= reduction;
            excess -= reduction;
        }
        self.sync_buffer();
        self.status = "scaled volumes to selected disk capacity".to_string();
    }

    pub fn enable_manual_storage(&mut self) {
        self.manual_storage = true;
        self.status = "manual layout enabled — press Enter to edit pools and volumes".to_string();
    }

    pub fn insert(&mut self, ch: char) {
        match self.current().kind() {
            StepKind::Password => {
                if !ch.is_control() {
                    if self.current() == Step::PasswordConfirm {
                        self.password_confirm.push(ch);
                    } else {
                        self.password.push(ch);
                    }
                }
            }
            StepKind::Text => {
                if !ch.is_control() {
                    self.edit_text(InputRequest::InsertChar(ch));
                }
            }
            StepKind::Confirm => {
                if !ch.is_control() {
                    self.confirm_input.push(ch);
                }
            }
            StepKind::Editor(editor) => {
                if editor.is_text(self.field) && !ch.is_control() {
                    self.edit_text(InputRequest::InsertChar(ch));
                }
            }
            _ => {}
        }
    }

    pub fn backspace(&mut self) {
        match self.current().kind() {
            StepKind::Password => {
                if self.current() == Step::PasswordConfirm {
                    self.password_confirm.pop();
                } else {
                    self.password.pop();
                }
            }
            StepKind::Text => {
                self.edit_text(InputRequest::DeletePrevChar);
            }
            StepKind::Confirm => {
                self.confirm_input.pop();
            }
            StepKind::Editor(editor) => {
                if editor.is_text(self.field) {
                    self.edit_text(InputRequest::DeletePrevChar);
                }
            }
            _ => {}
        }
    }

    pub fn add_item(&mut self) {
        self.flush_editor();
        match self.editor() {
            Some(Editor::Disks) => {
                let path = format!("/dev/disk{}", self.state.disks.len());
                self.state
                    .disk_roles
                    .insert(path.clone(), DiskRole::PoolMember);
                self.state.disks.push(DiskChoice {
                    path,
                    size_gib: 256,
                    model: Some("manual".to_string()),
                });
                self.item = self.state.disks.len() - 1;
            }
            Some(Editor::Pools) => {
                let name = unique_name("pool", &self.pool_names());
                self.state.volume_groups.push(VolumeGroupDraft { name });
                self.item = self.state.volume_groups.len() - 1;
            }
            Some(Editor::Volumes) => {
                let name = unique_name(
                    "vol",
                    &self
                        .state
                        .volumes
                        .iter()
                        .map(|v| v.name.clone())
                        .collect::<Vec<_>>(),
                );
                let pool = self
                    .pool_names()
                    .first()
                    .cloned()
                    .unwrap_or_else(|| DEFAULT_STORAGE_POOL_NAME.to_string());
                self.state.volumes.push(Volume {
                    name: name.clone(),
                    mountpoint: Mountpoint::Path(format!("/{name}")),
                    size_gib: 16,
                });
                self.state.set_volume_group_for_volume(&name, &pool);
                self.item = self.state.volumes.len() - 1;
            }
            Some(Editor::DocSubvols) => {
                let name = unique_name("sub", &self.state.doc_subvolumes);
                self.state.doc_subvolumes.push(name);
                self.item = self.state.doc_subvolumes.len() - 1;
            }
            None => {}
        }
        self.field = 0;
        self.sync_buffer();
    }

    pub fn remove_item(&mut self) {
        match self.editor() {
            Some(Editor::Disks) => {
                if self.item < self.state.disks.len() {
                    let path = self.state.disks[self.item].path.clone();
                    self.state.disks.remove(self.item);
                    self.state.disk_roles.remove(&path);
                    self.state.disk_volume_groups.remove(&path);
                    self.state.normalize_disk_roles();
                }
            }
            Some(Editor::Pools) => {
                if self.state.volume_groups.len() > 1 && self.item < self.state.volume_groups.len()
                {
                    self.state.volume_groups.remove(self.item);
                    self.state.normalize_storage_assignments();
                } else {
                    self.status = "keep at least one pool".to_string();
                }
            }
            Some(Editor::Volumes) => {
                if self.item < self.state.volumes.len() {
                    let name = self.state.volumes[self.item].name.clone();
                    self.state.volumes.remove(self.item);
                    self.state.volume_volume_groups.remove(&name);
                }
            }
            Some(Editor::DocSubvols) => {
                if self.item < self.state.doc_subvolumes.len() {
                    self.state.doc_subvolumes.remove(self.item);
                }
            }
            None => {}
        }
        let count = self.item_count();
        if count > 0 {
            self.item = self.item.min(count - 1);
        } else {
            self.item = 0;
        }
        self.field = 0;
        self.sync_buffer();
    }

    /// The text value of the currently focused editor text field.
    fn editor_text_value(&self) -> Option<String> {
        let editor = self.editor()?;
        if !editor.is_text(self.field) {
            return None;
        }
        match editor {
            Editor::Disks => {
                let disk = self.state.disks.get(self.item)?;
                Some(if self.field == 2 {
                    disk.path.clone()
                } else {
                    disk.size_gib.to_string()
                })
            }
            Editor::Volumes => {
                let vol = self.state.volumes.get(self.item)?;
                Some(match self.field {
                    0 => vol.name.clone(),
                    1 => vol.mountpoint.label().to_string(),
                    _ => vol.size_gib.to_string(),
                })
            }
            Editor::Pools => Some(self.state.volume_groups.get(self.item)?.name.clone()),
            Editor::DocSubvols => self.state.doc_subvolumes.get(self.item).cloned(),
        }
    }

    /// Write the buffer back into the focused text field, fixing any references.
    fn flush_editor(&mut self) {
        let Some(editor) = self.editor() else { return };
        if !editor.is_text(self.field) {
            return;
        }
        let value = self.buffer.trim().to_string();
        match editor {
            Editor::Disks => {
                let Some(disk) = self.state.disks.get(self.item).cloned() else {
                    return;
                };
                if self.field == 2 {
                    if !value.is_empty() && value != disk.path {
                        self.rename_disk(&disk.path, &value);
                    }
                } else if let Ok(size) = value.parse::<u64>() {
                    if let Some(d) = self.state.disks.get_mut(self.item) {
                        d.size_gib = size;
                    }
                }
            }
            Editor::Volumes => {
                let Some(vol) = self.state.volumes.get(self.item).cloned() else {
                    return;
                };
                match self.field {
                    0 => {
                        if !value.is_empty() && value != vol.name {
                            self.rename_volume(&vol.name, &value);
                        }
                    }
                    1 => {
                        if let Some(v) = self.state.volumes.get_mut(self.item) {
                            v.mountpoint = if value == "swap" {
                                Mountpoint::Swap
                            } else if value.is_empty() {
                                Mountpoint::Path("/".to_string())
                            } else {
                                Mountpoint::Path(value)
                            };
                        }
                    }
                    _ => {
                        if let Ok(size) = value.parse::<u64>() {
                            if let Some(v) = self.state.volumes.get_mut(self.item) {
                                v.size_gib = size;
                            }
                        }
                    }
                }
            }
            Editor::Pools => {
                let Some(pool) = self.state.volume_groups.get(self.item).cloned() else {
                    return;
                };
                if !value.is_empty() && value != pool.name {
                    let _ = self.state.rename_volume_group(&pool.name, &value);
                }
            }
            Editor::DocSubvols => {
                if let Some(sub) = self.state.doc_subvolumes.get_mut(self.item) {
                    if !value.is_empty() {
                        *sub = value;
                    }
                }
            }
        }
    }

    fn rename_disk(&mut self, old: &str, new: &str) {
        if let Some(disk) = self.state.disks.iter_mut().find(|d| d.path == old) {
            disk.path = new.to_string();
        }
        if let Some(role) = self.state.disk_roles.remove(old) {
            self.state.disk_roles.insert(new.to_string(), role);
        }
        if let Some(vg) = self.state.disk_volume_groups.remove(old) {
            self.state.disk_volume_groups.insert(new.to_string(), vg);
        }
    }

    fn rename_volume(&mut self, old: &str, new: &str) {
        if let Some(vol) = self.state.volumes.iter_mut().find(|v| v.name == old) {
            vol.name = new.to_string();
        }
        if let Some(vg) = self.state.volume_volume_groups.remove(old) {
            self.state.volume_volume_groups.insert(new.to_string(), vg);
        }
    }

    // ── back / advance ──────────────────────────────────────────

    pub fn back(&mut self) {
        if self.pos == 0 {
            return;
        }
        self.flush_editor();
        self.pos -= 1;
        self.load();
    }

    pub fn advance(&mut self) {
        self.flush_editor();
        if let Err(err) = self.commit() {
            self.status = err;
            return;
        }
        self.status.clear();

        if self.current() == Step::Confirm {
            self.done = true;
            return;
        }
        if self.pos + 1 < self.steps().len() {
            self.pos += 1;
            self.load();
        }
    }

    fn commit(&mut self) -> Result<(), String> {
        match self.current() {
            Step::Scope => {
                self.state.scope = if self.cursor == 0 {
                    InstallScope::Local
                } else {
                    InstallScope::Remote
                };
                self.link = if self.state.scope == InstallScope::Local {
                    LinkState::Local
                } else {
                    LinkState::Offline
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
            Step::Locale => {
                if let Some((tz, _, _, _)) = TIMEZONES.get(self.cursor) {
                    self.state.timezone = tz.to_string();
                }
            }
            Step::Filesystem => {
                self.state.filesystem = if self.cursor == 0 {
                    Filesystem::Btrfs
                } else {
                    Filesystem::Ext4
                };
            }
            Step::Encrypt => self.state.encrypt = self.cursor == 1,
            Step::Overwrite => self.state.overwrite_existing_storage = self.cursor == 1,
            Step::NetworkCleanup => self.state.network_route_cleanup = self.cursor == 0,
            Step::BinEnsure => self.state.skip_bin_ensure = self.cursor == 0,
            Step::StorageMode => {
                self.manual_storage = self.cursor == 3;
                self.state.storage_mode = match self.cursor {
                    0 => StorageMode::SingleDisk,
                    1 => StorageMode::JoinedLvm,
                    2 => StorageMode::SeparatePools,
                    // `StorageMode::Manual` is a programmatic unsupported
                    // layout. The UI's Manual… choice instead opens the rich
                    // editors while retaining a renderable storage strategy.
                    _ if self.state.disks.len() <= 1 => StorageMode::SingleDisk,
                    _ => StorageMode::JoinedLvm,
                };
            }
            Step::Remote => {
                let value = self.buffer.trim();
                if !value.contains('@') || value.starts_with('@') || value.ends_with('@') {
                    return Err("remote should look like user@host".to_string());
                }
                self.state.remote = value.to_string();
                self.begin_remote_probe();
            }
            Step::Mountpoint => {
                let value = self.buffer.trim();
                validate_mountpoint(value).map_err(|e| e.to_string())?;
                self.state.mountpoint = value.to_string();
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
                self.state.dotfiles_repo = (!value.is_empty()).then(|| value.to_string());
            }
            Step::Lvm => {
                self.state.use_lvm = self.cursor == 0;
                self.state.storage_mode = if self.state.use_lvm {
                    StorageMode::JoinedLvm
                } else {
                    StorageMode::SingleDisk
                };
            }
            Step::Disks => {
                if self.disk_selected.is_empty() {
                    return Err("select at least one disk (space to toggle)".to_string());
                }
                if !self.state.use_lvm && self.disk_selected.len() > 1 {
                    return Err("plain layout supports a single disk — deselect the rest".to_string());
                }
                self.apply_disk_selection();
            }
            Step::Efi => {
                self.state.esp_size_mib = match self.cursor {
                    0 => 512,
                    2 => 2048,
                    _ => 1024,
                };
            }
            Step::Storage => {
                self.state.normalize_disk_roles();
                self.state.normalize_storage_assignments();
            }
            Step::Volumes => {
                self.state.normalize_storage_assignments();
            }
            Step::PasswordConfirm => {
                if self.password_confirm != self.password {
                    return Err("passwords do not match".to_string());
                }
            }
            Step::ExtraDisks | Step::Password | Step::Pools | Step::DocSubvols => {}
            Step::Review => {
                if !self.preflight.as_ref().is_some_and(PreflightReport::pass) {
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

    pub fn toggle(&mut self, repo: &std::path::Path) {
        if self.current() == Step::Review {
            self.preflight = Some(crate::install::preflight::run(repo, &self.state));
            self.status = "preflight complete".to_string();
        }
    }

    pub fn confirm_phrase(&self) -> String {
        crate::install::confirm::DestructiveConfirmation::from_state(&self.state).phrase
    }

    pub fn confirm_armed(&self) -> bool {
        self.confirm_input.trim() == self.confirm_phrase()
    }

    pub fn commit_password(&mut self) -> Result<(), String> {
        self.state.user_password_hash = if self.password.is_empty() {
            None
        } else {
            Some(crate::install::secrets::hash_password(&self.password)?)
        };
        Ok(())
    }
}

fn cycle_pool(pools: &[String], current: Option<&str>) -> Option<String> {
    if pools.is_empty() {
        return None;
    }
    let idx = current
        .and_then(|c| pools.iter().position(|p| p == c))
        .map(|i| (i + 1) % pools.len())
        .unwrap_or(0);
    Some(pools[idx].clone())
}

fn apply_delta(value: u64, delta: i64) -> u64 {
    if delta >= 0 {
        value.saturating_add(delta as u64)
    } else {
        value.saturating_sub((-delta) as u64)
    }
}

fn unique_name(base: &str, existing: &[String]) -> String {
    if !existing.iter().any(|n| n == base) {
        return base.to_string();
    }
    (1..)
        .map(|i| format!("{base}{i}"))
        .find(|n| !existing.contains(n))
        .unwrap()
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
        let mut f = Flow::new(InstallState::draft());
        f.disable_discovery = true; // keep unit tests pure
        let disk = DiskChoice {
            path: "/dev/testdisk".into(),
            size_gib: 465,
            model: Some("test disk".into()),
        };
        f.state.disks = vec![disk.clone()];
        f.state.disk_roles.insert(disk.path, DiskRole::System);
        f.state.normalize_storage_assignments();
        f
    }

    fn walk_to(f: &mut Flow, target: Step) {
        // advance with valid defaults until we reach target (safety-bounded)
        for _ in 0..40 {
            if f.current() == target {
                return;
            }
            f.advance();
        }
        panic!("never reached {target:?}");
    }

    #[test]
    fn disk_editor_resize_takes_from_fill_volume() {
        let mut f = flow();
        f.cursor = 0; // local
        walk_to(&mut f, Step::Storage);
        // seed a target disk + pool so there is capacity and a fill volume.
        f.state.disks.push(DiskChoice {
            path: "/dev/sda".into(),
            size_gib: 1000,
            model: None,
        });
        f.state
            .disk_roles
            .insert("/dev/sda".into(), DiskRole::System);
        f.state
            .disk_volume_groups
            .insert("/dev/sda".into(), DEFAULT_STORAGE_POOL_NAME.into());
        f.state.fit_volumes_to_disk();

        f.disk_focus_volumes();
        // select "root" (first volume in the pool)
        f.vol_sel = f
            .volumes_in_selected_pool()
            .iter()
            .position(|&i| f.state.volumes[i].name == "root")
            .unwrap();
        let root_i = f
            .volumes_in_selected_pool()
            .into_iter()
            .find(|&i| f.state.volumes[i].name == "root")
            .unwrap();
        let home_i = f
            .state
            .volumes
            .iter()
            .position(|v| v.name == "home")
            .unwrap();
        let root_before = f.state.volumes[root_i].size_gib;
        let home_before = f.state.volumes[home_i].size_gib;
        f.disk_resize(8);
        assert_eq!(f.state.volumes[root_i].size_gib, root_before + 8);
        assert_eq!(f.state.volumes[home_i].size_gib, home_before - 8);
    }

    #[test]
    fn disk_editor_add_and_delete_volume_in_pool() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.disk_focus_volumes();
        let before = f.volumes_in_selected_pool().len();
        f.disk_add();
        assert_eq!(f.volumes_in_selected_pool().len(), before + 1);
        f.disk_delete();
        assert_eq!(f.volumes_in_selected_pool().len(), before);
    }

    #[test]
    fn simple_flow_skips_advanced_editors_until_manual_layout_is_enabled() {
        let mut f = flow();
        f.cursor = 0; // local
        f.advance();
        let steps = f.steps();
        for s in [
            Step::Scope,
            Step::Mountpoint,
            Step::Locale,
            Step::Hostname,
            Step::Role,
            Step::Ssh,
            Step::Lvm,
            Step::Encrypt,
            Step::Filesystem,
            Step::Disks,
            Step::Efi,
            Step::Storage,
            Step::DocSubvols, // btrfs draft
            Step::Overwrite,
            Step::NetworkCleanup,
            Step::BinEnsure,
            Step::Dotfiles,
            Step::User,
            Step::Password,
            Step::PasswordConfirm,
            Step::Review,
            Step::Confirm,
        ] {
            assert!(steps.contains(&s), "missing step {s:?}");
        }
        // Storage decisions come before disk selection; account comes last.
        let idx = |s: Step| steps.iter().position(|x| *x == s).unwrap();
        assert!(idx(Step::Lvm) < idx(Step::Disks), "LVM/LUKS decided before disks");
        assert!(idx(Step::Encrypt) < idx(Step::Disks), "encryption decided before disks");
        assert!(idx(Step::Disks) < idx(Step::Efi), "disk before boot");
        assert!(idx(Step::Efi) < idx(Step::Storage), "boot before storage layout");
        assert!(idx(Step::User) > idx(Step::Storage), "user account comes last");
    }

    #[test]
    fn ext4_hides_doc_subvolumes() {
        let mut f = flow();
        f.manual_storage = true;
        f.state.filesystem = Filesystem::Ext4;
        assert!(!f.steps().contains(&Step::DocSubvols));
        f.state.filesystem = Filesystem::Btrfs;
        assert!(f.steps().contains(&Step::DocSubvols));
    }

    #[test]
    fn storage_editor_renames_pool() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.disk_focus_pools();
        f.disk_begin_rename();
        // clear + type a new name
        while f.disk_rename.as_deref().map(|s| !s.is_empty()).unwrap_or(false) {
            f.disk_rename_backspace();
        }
        for ch in "fast".chars() {
            f.disk_rename_insert(ch);
        }
        f.disk_apply_rename();
        assert!(f.state.volume_groups.iter().any(|g| g.name == "fast"));
        assert!(f.disk_rename.is_none());
    }

    #[test]
    fn storage_editor_adds_and_deletes_pool() {
        let mut f = flow();
        f.cursor = 0; // local
        walk_to(&mut f, Step::Storage);
        f.disk_focus_pools();
        let n = f.pool_count();
        f.disk_add();
        assert_eq!(f.pool_count(), n + 1);
        f.disk_delete();
        assert_eq!(f.pool_count(), n);
    }

    #[test]
    fn manual_layout_opens_doc_subvolumes_after_storage() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.enable_manual_storage();
        f.advance();
        assert_eq!(f.current(), Step::DocSubvols);
    }

    #[test]
    fn discovered_empty_disk_is_selected_instead_of_a_draft_path() {
        let mut f = flow();
        f.state.disks.clear();
        f.state.disk_roles.clear();
        let facts = TargetFacts {
            mem_mib: Some(16 * 1024),
            disks: vec![
                crate::facts::DiskFacts {
                    path: "/dev/system".into(),
                    size_bytes: 2_000 * 1024 * 1024 * 1024,
                    partitions: vec![crate::facts::PartitionFacts {
                        path: "/dev/system1".into(),
                        size_bytes: 1_000 * 1024 * 1024 * 1024,
                        fstype: Some("ext4".into()),
                        label: None,
                        mountpoints: vec!["/".into()],
                    }],
                    ..crate::facts::DiskFacts::default()
                },
                crate::facts::DiskFacts {
                    path: "/dev/empty".into(),
                    size_bytes: 500 * 1024 * 1024 * 1024,
                    ..crate::facts::DiskFacts::default()
                },
            ],
            ..TargetFacts::default()
        };

        f.accept_facts(facts);

        assert_eq!(f.state.disks.len(), 1);
        assert_eq!(f.state.disks[0].path, "/dev/empty");
        assert_eq!(f.state.storage_mode, StorageMode::SingleDisk);
        assert_eq!(
            f.state
                .volumes
                .iter()
                .find(|volume| matches!(volume.mountpoint, Mountpoint::Swap))
                .unwrap()
                .size_gib,
            16
        );
    }

    #[test]
    fn text_input_edits_at_the_tui_input_cursor() {
        let mut f = flow();
        f.cursor = 0; // local
        f.advance();
        assert_eq!(f.current(), Step::Mountpoint);
        f.text_cursor_prev();
        f.insert('X');
        assert_eq!(f.buffer, "/mnXt");
        assert_eq!(f.text_cursor(), 4);
    }

    #[test]
    fn scale_to_fit_reduces_an_over_capacity_plan() {
        let mut f = flow();
        f.state.disks[0].size_gib = 100;
        assert!(f.state.used_gib() > f.state.total_disk_gib());
        f.scale_to_fit();
        assert_eq!(f.state.used_gib(), f.state.total_disk_gib());
        assert!(f.state.volumes.iter().all(|volume| volume.size_gib >= 1));
    }

    #[test]
    fn network_and_bin_toggles_apply() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::NetworkCleanup);
        f.cursor = 1; // no
        f.advance();
        assert!(!f.state.network_route_cleanup);
        assert_eq!(f.current(), Step::BinEnsure);
        f.cursor = 1; // run
        f.advance();
        assert!(!f.state.skip_bin_ensure);
    }
}
