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
    validate_mountpoint, DiskChoice, DiskRole, DiskSlice, Filesystem, InstallRole, InstallScope,
    InstallState, Mountpoint, StorageMode, Subvolume, UserAccount, Volume, VolumeFs,
    VolumeGroupDraft, DEFAULT_STORAGE_POOL_NAME,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Scope,
    Remote,
    Mountpoint,
    Hostname,
    #[allow(dead_code)]
    User,
    #[allow(dead_code)]
    Password,
    #[allow(dead_code)]
    PasswordConfirm,
    Role,
    Ssh,
    Locale,
    Lvm,
    Encrypt,
    // Filesystem is now chosen per-volume in the Storage editor, not globally.
    #[allow(dead_code)]
    Filesystem,
    // Disk selection + EFI are now folded into the single Storage editor.
    #[allow(dead_code)]
    Disks,
    #[allow(dead_code)]
    StorageMode,
    #[allow(dead_code)]
    Efi,
    Storage,
    ExtraDisks,
    // Retained for the generic editor + manual paths; the Storage two-panel
    // editor now covers pools/volumes in the default flow.
    #[allow(dead_code)]
    Pools,
    #[allow(dead_code)]
    Volumes,
    // Subvolumes are now per-btrfs-volume in the Storage editor, not a global step.
    #[allow(dead_code)]
    DocSubvols,
    Overwrite,
    NetworkCleanup,
    BinEnsure,
    Users,
    #[allow(dead_code)]
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
            Step::Users => "users",
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
            Step::Storage => "Slice disks into pools, then partition a pool",
            Step::ExtraDisks => "Configure the remaining disks?",
            Step::Pools => "Volume groups (LVM pools)",
            Step::Volumes => "Logical volumes",
            Step::DocSubvols => "btrfs subvolumes under /doc",
            Step::Overwrite => "Existing data on the disk?",
            Step::NetworkCleanup => "Clean up competing network routes?",
            Step::BinEnsure => "Provision extra binaries after install?",
            Step::Users => "User accounts",
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
            Step::Storage => "Enter drills in · Esc goes back · first disk holds EFI.",
            Step::ExtraDisks => "Disks not used by the install — set a mount for each, or skip. Boot media is ignored.",
            Step::Pools => "One LVM volume group per pool. type rename · ^n add · ^x remove.",
            Step::Volumes => "↑↓ vol · ←→ field · space cycle · type edit · +/- size · ^n/^x.",
            Step::DocSubvols => "Subvolumes carved under /doc. type edit · ^n add · ^x remove.",
            Step::Overwrite => "Allow wiping an existing LVM volume group if one is present.",
            Step::NetworkCleanup => {
                "Remove extra default routes that can break the remote SSH link."
            }
            Step::BinEnsure => "Run the `bin` provisioner in the installed system (needs a token).",
            Step::Users => "↑↓ user · a add · d delete · n name · p password · f dotfiles · g groups.",
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
            Step::Users => StepKind::Users,
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
    /// Multi-user account editor.
    Users,
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

/// The storage editor is a nested set of full-screen sub-pages you drill through:
/// DISKS (sliced into pools) → POOLS → the selected pool's PARTITIONS. `Enter`
/// goes deeper, `Esc` walks back up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskStage {
    Disks,
    Pools,
    Partitions,
}

impl DiskStage {
    pub fn title(self) -> &'static str {
        match self {
            DiskStage::Disks => "disks",
            DiskStage::Pools => "pools",
            DiskStage::Partitions => "partitions",
        }
    }
}

/// Which text field of a partition is being edited in the storage editor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PartField {
    Name,
    Mount,
}

/// Text field of a user being edited in the Users step.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UserField {
    Name,
    Password,
    Dotfiles,
}

/// Which text field of a btrfs subvolume is being edited.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubvolField {
    Name,
    Mount,
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
    /// Storage editor: which drill-down sub-page is showing, and the selection
    /// on each.
    pub disk_stage: DiskStage,
    /// Cursor in the DISKS page (index into the flattened slice rows).
    pub disk_cursor: usize,
    /// Selected pool (POOLS page + the pool drilled into for partitions).
    pub pool_sel: usize,
    /// Cursor in the PARTITIONS view (index into volumes in the selected pool).
    pub vol_sel: usize,
    /// When editing a partition's name/mount, the in-progress text + field.
    pub disk_rename: Option<String>,
    pub disk_edit_field: PartField,
    /// Typing an exact size in GiB for the selected item on the current page.
    pub size_edit: Option<String>,
    /// Subvolume sub-editor: the target volume index (Some while open), the
    /// selected subvolume, and an in-progress name/mount edit.
    pub subvol_target: Option<usize>,
    pub subvol_sel: usize,
    pub subvol_edit: Option<(SubvolField, String)>,
    /// Disk paths selected for the install (multi for LVM, one for plain).
    pub disk_selected: BTreeSet<String>,
    /// Cursor + mount-edit state for the extra-disks step.
    pub extra_sel: usize,
    pub extra_edit: Option<String>,
    /// Users editor: selected user, an in-progress text field edit, and the
    /// group-selection cursor (Some while editing groups).
    pub user_sel: usize,
    pub user_edit: Option<(UserField, String)>,
    pub group_cursor: Option<usize>,
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
            disk_stage: DiskStage::Disks,
            disk_cursor: 0,
            pool_sel: 0,
            vol_sel: 0,
            disk_rename: None,
            disk_edit_field: PartField::Name,
            size_edit: None,
            subvol_target: None,
            subvol_sel: 0,
            subvol_edit: None,
            disk_selected: BTreeSet::new(),
            extra_sel: 0,
            extra_edit: None,
            user_sel: 0,
            user_edit: None,
            group_cursor: None,
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

        // Storage: decide the TYPE first (LVM? then LUKS?), then everything else
        // happens in ONE disk editor — pick the disks that make the pool (first
        // gets EFI), then carve partitions with per-partition fs + subvolumes.
        steps.extend([Step::Lvm, Step::Encrypt, Step::Storage]);
        steps.push(Step::Overwrite);
        // Remaining disks (not the install target, not boot media) → mounts.
        if !self.extra_disks().is_empty() {
            steps.push(Step::ExtraDisks);
        }

        // System extras.
        steps.extend([Step::NetworkCleanup, Step::BinEnsure]);

        // User accounts at the very end (name/password/dotfiles/groups per user).
        steps.push(Step::Users);

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

    // ── users editor ─────────────────────────────────────────────

    pub fn user_count(&self) -> usize {
        self.state.users.len()
    }

    pub fn users_sel_next(&mut self) {
        let n = self.user_count();
        if n > 0 {
            self.user_sel = (self.user_sel + 1) % n;
        }
    }

    pub fn users_sel_prev(&mut self) {
        let n = self.user_count();
        if n > 0 {
            self.user_sel = (self.user_sel + n - 1) % n;
        }
    }

    pub fn users_add(&mut self) {
        let name = unique_name(
            "user",
            &self.state.users.iter().map(|u| u.name.clone()).collect::<Vec<_>>(),
        );
        self.state.users.push(UserAccount {
            name,
            password_hash: None,
            dotfiles: None,
            groups: crate::install::state::default_user_groups(),
        });
        self.user_sel = self.state.users.len() - 1;
    }

    pub fn users_delete(&mut self) {
        // Keep at least the primary account.
        if self.state.users.len() > 1 {
            self.state.users.remove(self.user_sel);
            self.user_sel = self.user_sel.min(self.state.users.len() - 1);
        } else {
            self.status = "keep at least one user".to_string();
        }
    }

    pub fn user_begin_edit(&mut self, field: UserField) {
        let Some(user) = self.state.users.get(self.user_sel) else {
            return;
        };
        let start = match field {
            UserField::Name => user.name.clone(),
            // Never surface the hash; password is always retyped fresh.
            UserField::Password => String::new(),
            UserField::Dotfiles => user.dotfiles.clone().unwrap_or_default(),
        };
        self.user_edit = Some((field, start));
    }

    pub fn user_edit_insert(&mut self, ch: char) {
        if let Some((field, buf)) = self.user_edit.as_mut() {
            let ok = match field {
                UserField::Name => !ch.is_whitespace(),
                UserField::Password => !ch.is_control(),
                UserField::Dotfiles => !ch.is_whitespace(),
            };
            if ok && !ch.is_control() {
                buf.push(ch);
            }
        }
    }

    pub fn user_edit_backspace(&mut self) {
        if let Some((_, buf)) = self.user_edit.as_mut() {
            buf.pop();
        }
    }

    pub fn user_cancel_edit(&mut self) {
        self.user_edit = None;
    }

    pub fn user_apply_edit(&mut self) -> Result<(), String> {
        let Some((field, buf)) = self.user_edit.take() else {
            return Ok(());
        };
        let value = buf.trim().to_string();
        let Some(user) = self.state.users.get_mut(self.user_sel) else {
            return Ok(());
        };
        match field {
            UserField::Name => {
                if !value.is_empty() {
                    user.name = value;
                }
            }
            UserField::Dotfiles => {
                user.dotfiles = (!value.is_empty()).then_some(value);
            }
            UserField::Password => {
                user.password_hash = if value.is_empty() {
                    None
                } else {
                    Some(crate::install::secrets::hash_password(&value)?)
                };
            }
        }
        Ok(())
    }

    /// The in-progress edit buffer, and whether it should be masked.
    pub fn user_edit_view(&self) -> Option<(UserField, &str)> {
        self.user_edit.as_ref().map(|(f, b)| (*f, b.as_str()))
    }

    // group multi-select sub-mode
    pub fn group_begin(&mut self) {
        self.group_cursor = Some(0);
    }

    pub fn group_close(&mut self) {
        self.group_cursor = None;
    }

    pub fn group_move(&mut self, delta: i64) {
        let len = crate::install::state::AVAILABLE_GROUPS.len();
        if let Some(c) = self.group_cursor.as_mut() {
            let n = len as i64;
            *c = (((*c as i64) + delta).rem_euclid(n)) as usize;
        }
    }

    pub fn group_toggle(&mut self) {
        let Some(cursor) = self.group_cursor else {
            return;
        };
        let Some(group) = crate::install::state::AVAILABLE_GROUPS.get(cursor) else {
            return;
        };
        let group = group.to_string();
        if let Some(user) = self.state.users.get_mut(self.user_sel) {
            if let Some(pos) = user.groups.iter().position(|g| *g == group) {
                user.groups.remove(pos);
            } else {
                user.groups.push(group);
            }
        }
    }

    pub fn user_has_group(&self, group: &str) -> bool {
        self.state
            .users
            .get(self.user_sel)
            .map(|u| u.groups.iter().any(|g| g == group))
            .unwrap_or(false)
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
        // Drop slices for disks that left the selection; keep the rest so a
        // user's split survives re-entering the editor.
        let keep: std::collections::BTreeSet<String> =
            selected.iter().map(|d| d.path.clone()).collect();
        self.state.disk_slices.retain(|path, _| keep.contains(path));
        for disk in &selected {
            self.state
                .disk_roles
                .insert(disk.path.clone(), DiskRole::System);
        }
        self.state.normalize_disk_roles();
        // Any newly-added disk with no slices gets a whole-disk slice in the
        // default pool via normalize.
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

    #[allow(dead_code)]
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

    /// A pool's capacity is the sum of the disk slices assigned to it.
    pub fn pool_capacity_gib(&self, pool: &str) -> u64 {
        self.state.pool_capacity_gib(pool)
    }

    pub fn pool_used_gib(&self, pool: &str) -> u64 {
        self.state
            .volumes
            .iter()
            .filter(|v| self.state.volume_group_for_volume(&v.name) == pool)
            .map(|v| v.size_gib)
            .sum()
    }

    // ── sub-page navigation (disks → pools → partitions) ────────

    pub fn goto_disks(&mut self) {
        self.disk_stage = DiskStage::Disks;
        let n = self.slice_rows().len();
        if n > 0 {
            self.disk_cursor = self.disk_cursor.min(n - 1);
        }
    }

    pub fn goto_pools(&mut self) {
        self.disk_stage = DiskStage::Pools;
        let n = self.pool_count();
        if n > 0 {
            self.pool_sel = self.pool_sel.min(n - 1);
        }
    }

    /// `Enter`: drill one page deeper, or advance the whole flow from the last
    /// page. disks → pools → (selected pool) partitions → next step.
    pub fn storage_forward(&mut self) {
        match self.disk_stage {
            DiskStage::Disks => self.goto_pools(),
            DiskStage::Pools => self.pool_enter(),
            DiskStage::Partitions => self.advance(),
        }
    }

    /// `Esc`: walk one page back up, or leave the storage step from the top.
    pub fn storage_back(&mut self) {
        match self.disk_stage {
            DiskStage::Partitions => self.goto_pools(),
            DiskStage::Pools => self.goto_disks(),
            DiskStage::Disks => self.back(),
        }
    }

    /// Rows for the DISKS page in disk order. A disk in the install set yields
    /// one row per slice (`Some(idx)`); an unused disk yields a single
    /// placeholder row (`None`) that can be toggled into the layout.
    pub fn slice_rows(&self) -> Vec<(String, Option<usize>)> {
        let mut rows = Vec::new();
        for disk in self.installable_disks() {
            if self.disk_selected.contains(&disk.path) {
                let count = self.state.slices_for_disk(&disk.path).len().max(1);
                for i in 0..count {
                    rows.push((disk.path.clone(), Some(i)));
                }
            } else {
                rows.push((disk.path.clone(), None));
            }
        }
        rows
    }

    /// The selected (disk, slice_index), or None when the cursor is on an unused
    /// disk's placeholder row.
    pub fn selected_slice(&self) -> Option<(String, usize)> {
        match self.slice_rows().get(self.disk_cursor) {
            Some((path, Some(idx))) => Some((path.clone(), *idx)),
            _ => None,
        }
    }

    /// The disk under the DISKS-pane cursor (whether used or not).
    pub fn cursor_disk(&self) -> Option<String> {
        self.slice_rows().get(self.disk_cursor).map(|(p, _)| p.clone())
    }

    /// Toggle the disk under the cursor into/out of the install layout. Adding a
    /// disk gives it a whole-disk slice in the selected pool; the last install
    /// disk cannot be removed.
    pub fn disk_row_toggle_selected(&mut self) {
        let Some(path) = self.cursor_disk() else {
            return;
        };
        if self.disk_selected.contains(&path) {
            if self.disk_selected.len() == 1 {
                self.status = "keep at least one disk in the install".to_string();
                return;
            }
            self.disk_toggle(&path);
        } else {
            self.disk_toggle(&path);
        }
        self.apply_disk_selection();
    }

    pub fn disk_sel_next(&mut self) {
        match self.disk_stage {
            DiskStage::Disks => {
                let n = self.slice_rows().len();
                if n > 0 {
                    self.disk_cursor = (self.disk_cursor + 1) % n;
                }
            }
            DiskStage::Pools => {
                let n = self.pool_count();
                if n > 0 {
                    self.pool_sel = (self.pool_sel + 1) % n;
                }
            }
            DiskStage::Partitions => {
                let n = self.volumes_in_selected_pool().len();
                if n > 0 {
                    self.vol_sel = (self.vol_sel + 1) % n;
                }
            }
        }
    }

    pub fn disk_sel_prev(&mut self) {
        match self.disk_stage {
            DiskStage::Disks => {
                let n = self.slice_rows().len();
                if n > 0 {
                    self.disk_cursor = (self.disk_cursor + n - 1) % n;
                }
            }
            DiskStage::Pools => {
                let n = self.pool_count();
                if n > 0 {
                    self.pool_sel = (self.pool_sel + n - 1) % n;
                }
            }
            DiskStage::Partitions => {
                let n = self.volumes_in_selected_pool().len();
                if n > 0 {
                    self.vol_sel = (self.vol_sel + n - 1) % n;
                }
            }
        }
    }

    /// Cycle the selected slice through the available pools — this is how a disk
    /// (or part of it) is moved from one pool to another.
    pub fn slice_cycle_pool(&mut self) {
        let Some((path, idx)) = self.selected_slice() else {
            return;
        };
        let pools: Vec<String> = self.state.volume_groups.iter().map(|g| g.name.clone()).collect();
        if pools.len() < 2 {
            self.status = "add another pool first (a in the pools panel)".to_string();
            return;
        }
        // Ensure the disk has a materialized slice list.
        self.ensure_slice(&path);
        if let Some(slices) = self.state.disk_slices.get_mut(&path) {
            if let Some(slice) = slices.get_mut(idx) {
                let cur = pools.iter().position(|p| *p == slice.pool).unwrap_or(0);
                slice.pool = pools[(cur + 1) % pools.len()].clone();
            }
        }
        self.state.normalize_storage_assignments();
    }

    /// Split the selected slice in two, giving the disk's free space (or half of
    /// the slice) to a new slice in the same pool — the user then recolors it.
    pub fn slice_split(&mut self) {
        let Some((path, idx)) = self.selected_slice() else {
            return;
        };
        self.ensure_slice(&path);
        let free = self.state.disk_free_gib(&path);
        let Some(slices) = self.state.disk_slices.get_mut(&path) else {
            return;
        };
        let Some(slice) = slices.get(idx) else { return };
        let pool = slice.pool.clone();
        let (keep, new) = if free > 0 {
            (slice.size_gib, free)
        } else {
            let half = (slice.size_gib / 2).max(1);
            (slice.size_gib - half, half)
        };
        if new == 0 {
            return;
        }
        slices[idx].size_gib = keep;
        slices.insert(idx + 1, DiskSlice { pool, size_gib: new });
        self.disk_cursor += 1;
    }

    /// Remove the selected slice (its space becomes free), unless it is the
    /// disk's only slice.
    pub fn slice_delete(&mut self) {
        let Some((path, idx)) = self.selected_slice() else {
            return;
        };
        let Some(slices) = self.state.disk_slices.get_mut(&path) else {
            return;
        };
        if slices.len() <= 1 {
            self.status = "a disk keeps at least one slice".to_string();
            return;
        }
        slices.remove(idx);
        self.disk_cursor = self.disk_cursor.saturating_sub(1);
        self.state.normalize_storage_assignments();
    }

    /// Resize the selected slice by `delta` GiB, bounded by the disk's free space.
    pub fn slice_resize(&mut self, delta: i64) {
        let Some((path, idx)) = self.selected_slice() else {
            return;
        };
        self.ensure_slice(&path);
        let free = self.state.disk_free_gib(&path) as i64;
        let Some(slices) = self.state.disk_slices.get_mut(&path) else {
            return;
        };
        let Some(slice) = slices.get_mut(idx) else { return };
        let cur = slice.size_gib as i64;
        // Growing is capped by free space; shrinking floors at 1.
        let delta = delta.min(free);
        slice.size_gib = (cur + delta).max(1) as u64;
    }

    /// Materialize a whole-disk slice for a disk that has none yet.
    fn ensure_slice(&mut self, path: &str) {
        if self.state.slices_for_disk(path).is_empty() {
            let esp = self.state.esp_reserved_gib(path);
            let whole = self.state.disk_size_gib(path).saturating_sub(esp);
            self.state.disk_slices.insert(
                path.to_string(),
                vec![DiskSlice {
                    pool: self
                        .selected_pool_name()
                        .unwrap_or_else(|| DEFAULT_STORAGE_POOL_NAME.to_string()),
                    size_gib: whole,
                }],
            );
        }
    }

    // ── type an exact size in GiB ────────────────────────────────

    pub fn size_editing(&self) -> bool {
        self.size_edit.is_some()
    }

    /// Start typing a size for the selected item on the current page. An
    /// optional first digit seeds the buffer (so pressing a number just works).
    pub fn size_begin(&mut self, first: Option<char>) {
        let ok = match self.disk_stage {
            DiskStage::Disks => self.selected_slice().is_some(),
            DiskStage::Pools => self.selected_pool_name().is_some(),
            DiskStage::Partitions => self.selected_volume_index().is_some(),
        };
        if !ok {
            return;
        }
        let mut buf = String::new();
        if let Some(c) = first {
            if c.is_ascii_digit() {
                buf.push(c);
            }
        }
        self.size_edit = Some(buf);
    }

    pub fn size_insert(&mut self, ch: char) {
        if let Some(buf) = self.size_edit.as_mut() {
            if ch.is_ascii_digit() && buf.len() < 7 {
                buf.push(ch);
            }
        }
    }

    pub fn size_backspace(&mut self) {
        if let Some(buf) = self.size_edit.as_mut() {
            buf.pop();
        }
    }

    pub fn size_cancel(&mut self) {
        self.size_edit = None;
    }

    pub fn size_apply(&mut self) {
        let Some(buf) = self.size_edit.take() else {
            return;
        };
        let Ok(val) = buf.trim().parse::<u64>() else {
            return;
        };
        let val = val.max(1);
        match self.disk_stage {
            DiskStage::Partitions => {
                if let Some(i) = self.selected_volume_index() {
                    self.state.volumes[i].size_gib = val;
                }
            }
            DiskStage::Disks => self.slice_set_size(val),
            DiskStage::Pools => self.pool_set_size(val),
        }
    }

    /// Set the selected slice to an absolute size (clamped to the disk).
    fn slice_set_size(&mut self, val: u64) {
        let Some((path, idx)) = self.selected_slice() else {
            return;
        };
        self.ensure_slice(&path);
        let free = self.state.disk_free_gib(&path);
        if let Some(slices) = self.state.disk_slices.get_mut(&path) {
            if let Some(slice) = slices.get_mut(idx) {
                let max = slice.size_gib + free;
                slice.size_gib = val.clamp(1, max.max(1));
            }
        }
    }

    // ── pool sizing (adjusts the slices feeding the pool) ────────

    /// The largest slice feeding a pool, as (disk, slice_index, size).
    fn largest_slice_of_pool(&self, pool: &str) -> Option<(String, usize, u64)> {
        let mut best: Option<(String, usize, u64)> = None;
        for (path, slices) in &self.state.disk_slices {
            for (i, s) in slices.iter().enumerate() {
                if s.pool == pool && best.as_ref().map_or(true, |(_, _, sz)| s.size_gib > *sz) {
                    best = Some((path.clone(), i, s.size_gib));
                }
            }
        }
        best
    }

    /// Grow/shrink the selected pool by `delta` GiB, adjusting its largest slice.
    pub fn pool_resize(&mut self, delta: i64) {
        let Some(pool) = self.selected_pool_name() else {
            return;
        };
        if let Some((path, idx, cur)) = self.largest_slice_of_pool(&pool) {
            let free = self.state.disk_free_gib(&path) as i64;
            let delta = delta.min(free);
            if let Some(slices) = self.state.disk_slices.get_mut(&path) {
                if let Some(slice) = slices.get_mut(idx) {
                    slice.size_gib = (cur as i64 + delta).max(1) as u64;
                }
            }
        } else if delta > 0 {
            // Pool has no space yet: claim free space from a selected disk.
            let disks: Vec<String> = self.disk_selected.iter().cloned().collect();
            for d in disks {
                if self.state.disk_free_gib(&d) > 0 {
                    self.state.add_disk_slice(&d, &pool, delta as u64);
                    break;
                }
            }
        }
    }

    /// Set the selected pool to an absolute capacity via its largest slice.
    fn pool_set_size(&mut self, val: u64) {
        let Some(pool) = self.selected_pool_name() else {
            return;
        };
        if let Some((path, idx, cur)) = self.largest_slice_of_pool(&pool) {
            let free = self.state.disk_free_gib(&path);
            if let Some(slices) = self.state.disk_slices.get_mut(&path) {
                if let Some(slice) = slices.get_mut(idx) {
                    let max = cur + free;
                    slice.size_gib = val.clamp(1, max.max(1));
                }
            }
        } else {
            let disks: Vec<String> = self.disk_selected.iter().cloned().collect();
            for d in disks {
                if self.state.disk_free_gib(&d) > 0 {
                    self.state.add_disk_slice(&d, &pool, val);
                    break;
                }
            }
        }
    }

    // ── pools ────────────────────────────────────────────────────

    /// Add a new empty pool and select it.
    pub fn pool_add(&mut self) {
        let name = self.state.create_next_volume_group();
        self.pool_sel = self
            .state
            .volume_groups
            .iter()
            .position(|g| g.name == name)
            .unwrap_or(0);
    }

    pub fn pool_begin_rename(&mut self) {
        if let Some(name) = self.selected_pool_name() {
            self.disk_edit_field = PartField::Name;
            self.disk_rename = Some(name);
        }
    }

    /// Delete the selected pool (its slices + volumes fall back to the default).
    pub fn pool_delete(&mut self) {
        let Some(name) = self.selected_pool_name() else {
            return;
        };
        match self.state.delete_volume_group_reassigning_to_default(&name) {
            Ok(()) => self.pool_sel = self.pool_sel.min(self.pool_count().saturating_sub(1)),
            Err(err) => self.status = err,
        }
    }

    /// Drill into the selected pool to edit its partitions.
    pub fn pool_enter(&mut self) {
        if self.volumes_in_selected_pool().is_empty() {
            // A pool needs at least one partition to work with.
            self.disk_add_to_pool();
        }
        self.disk_stage = DiskStage::Partitions;
        self.vol_sel = 0;
    }

    fn selected_volume_index(&self) -> Option<usize> {
        self.volumes_in_selected_pool().get(self.vol_sel).copied()
    }

    /// Resize the selected volume by `delta` GiB, taking the change from the
    /// pool's fill volume (`home`, else the largest other) so the pool stays
    /// balanced — like dragging a partition boundary.
    pub fn disk_resize(&mut self, delta: i64) {
        if self.disk_stage != DiskStage::Partitions {
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

    /// Add a partition to the selected pool.
    fn disk_add_to_pool(&mut self) {
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
            // Start small; the user grows it (type a number or −/+).
            size_gib: 1,
            fs: VolumeFs::Btrfs,
            subvolumes: Vec::new(),
        });
        self.state.set_volume_group_for_volume(&name, &pool);
        self.vol_sel = self.volumes_in_selected_pool().len().saturating_sub(1);
    }

    /// Add a partition (PARTITIONS view only).
    pub fn disk_add(&mut self) {
        if self.disk_stage != DiskStage::Partitions {
            return;
        }
        self.disk_add_to_pool();
    }

    /// Delete the selected partition (PARTITIONS view only).
    pub fn disk_delete(&mut self) {
        if self.disk_stage != DiskStage::Partitions {
            return;
        }
        if self.volumes_in_selected_pool().len() <= 1 {
            self.status = "the pool needs at least one partition".to_string();
            return;
        }
        if let Some(i) = self.selected_volume_index() {
            let name = self.state.volumes[i].name.clone();
            self.state.volumes.remove(i);
            self.state.volume_volume_groups.remove(&name);
            self.vol_sel = self.vol_sel.saturating_sub(1);
        }
    }

    // ── edit the selected partition's name / mountpoint ──────────

    pub fn disk_begin_edit(&mut self, field: PartField) {
        if self.disk_stage != DiskStage::Partitions {
            return;
        }
        let Some(i) = self.selected_volume_index() else {
            return;
        };
        self.disk_edit_field = field;
        self.disk_rename = Some(match field {
            PartField::Name => self.state.volumes[i].name.clone(),
            PartField::Mount => self.state.volumes[i].mountpoint.label().to_string(),
        });
    }

    pub fn disk_rename_insert(&mut self, ch: char) {
        if let Some(buf) = self.disk_rename.as_mut() {
            // Names forbid whitespace; mount paths allow the leading slash etc.
            let ok = match self.disk_edit_field {
                PartField::Name => !ch.is_control() && !ch.is_whitespace(),
                PartField::Mount => !ch.is_control() && !ch.is_whitespace(),
            };
            if ok {
                buf.push(ch);
            }
        }
    }

    pub fn disk_rename_backspace(&mut self) {
        if let Some(buf) = self.disk_rename.as_mut() {
            buf.pop();
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
        // Renaming a pool (POOLS page) vs a partition (PARTITIONS page).
        if self.disk_stage == DiskStage::Pools {
            if let Some(old) = self.selected_pool_name() {
                if old != new {
                    if let Err(err) = self.state.rename_volume_group(&old, &new) {
                        self.status = err;
                    }
                }
            }
            return;
        }
        let Some(i) = self.selected_volume_index() else {
            return;
        };
        match self.disk_edit_field {
            PartField::Name => {
                let old = self.state.volumes[i].name.clone();
                if old != new {
                    self.rename_volume(&old, &new);
                }
            }
            PartField::Mount => {
                if new == "swap" {
                    self.state.volumes[i].mountpoint = Mountpoint::Swap;
                    self.state.volumes[i].fs = VolumeFs::Swap;
                    self.state.volumes[i].subvolumes.clear();
                } else if let Err(err) = validate_mountpoint(&new) {
                    self.status = err;
                } else {
                    self.state.volumes[i].mountpoint = Mountpoint::Path(new);
                    if self.state.volumes[i].fs == VolumeFs::Swap {
                        self.state.volumes[i].fs = VolumeFs::Btrfs;
                    }
                }
            }
        }
    }

    // ── per-volume filesystem & subvolumes ──────────────────────

    /// Cycle the selected volume's filesystem (btrfs → ext4 → xfs → swap → …).
    /// Swap and non-swap filesystems keep the mountpoint kind consistent, and
    /// leaving btrfs drops any subvolumes since only btrfs supports them.
    pub fn disk_cycle_fs(&mut self) {
        if self.disk_stage != DiskStage::Partitions {
            return;
        }
        let Some(i) = self.selected_volume_index() else {
            return;
        };
        let next = self.state.volumes[i].fs.next();
        let volume = &mut self.state.volumes[i];
        volume.fs = next;
        match next {
            VolumeFs::Swap => {
                volume.mountpoint = Mountpoint::Swap;
                volume.subvolumes.clear();
            }
            VolumeFs::Btrfs => {
                if matches!(volume.mountpoint, Mountpoint::Swap) {
                    volume.mountpoint = Mountpoint::Path(format!("/{}", volume.name));
                }
            }
            VolumeFs::Ext4 | VolumeFs::Xfs => {
                if matches!(volume.mountpoint, Mountpoint::Swap) {
                    volume.mountpoint = Mountpoint::Path(format!("/{}", volume.name));
                }
                // Only btrfs carries subvolumes.
                volume.subvolumes.clear();
            }
        }
    }

    /// Open the subvolume sub-editor for the selected volume (btrfs only).
    pub fn subvol_open(&mut self) {
        if self.disk_stage != DiskStage::Partitions {
            return;
        }
        let Some(i) = self.selected_volume_index() else {
            return;
        };
        if !self.state.volumes[i].fs.is_btrfs() {
            self.status = "subvolumes need a btrfs volume (press f)".to_string();
            return;
        }
        self.subvol_target = Some(i);
        self.subvol_sel = 0;
        self.subvol_edit = None;
    }

    pub fn subvol_close(&mut self) {
        self.subvol_target = None;
        self.subvol_edit = None;
    }

    fn subvol_count(&self) -> usize {
        self.subvol_target
            .map(|i| self.state.volumes[i].subvolumes.len())
            .unwrap_or(0)
    }

    pub fn subvol_sel_next(&mut self) {
        let n = self.subvol_count();
        if n > 0 {
            self.subvol_sel = (self.subvol_sel + 1) % n;
        }
    }

    pub fn subvol_sel_prev(&mut self) {
        let n = self.subvol_count();
        if n > 0 {
            self.subvol_sel = (self.subvol_sel + n - 1) % n;
        }
    }

    pub fn subvol_add(&mut self) {
        let Some(i) = self.subvol_target else { return };
        let existing: Vec<String> = self.state.volumes[i]
            .subvolumes
            .iter()
            .map(|s| s.name.clone())
            .collect();
        let name = unique_name("sub", &existing);
        let mount = format!("{}/{}", self.state.volumes[i].mountpoint.label(), name)
            .replace("//", "/");
        self.state.volumes[i].subvolumes.push(Subvolume {
            name: name.clone(),
            mountpoint: mount,
        });
        self.subvol_sel = self.state.volumes[i].subvolumes.len() - 1;
    }

    pub fn subvol_delete(&mut self) {
        let Some(i) = self.subvol_target else { return };
        let subs = &mut self.state.volumes[i].subvolumes;
        if self.subvol_sel < subs.len() {
            subs.remove(self.subvol_sel);
            self.subvol_sel = self.subvol_sel.saturating_sub(1);
        }
    }

    pub fn subvol_begin_edit(&mut self, field: SubvolField) {
        let Some(i) = self.subvol_target else { return };
        let Some(sub) = self.state.volumes[i].subvolumes.get(self.subvol_sel) else {
            return;
        };
        let value = match field {
            SubvolField::Name => sub.name.clone(),
            SubvolField::Mount => sub.mountpoint.clone(),
        };
        self.subvol_edit = Some((field, value));
    }

    pub fn subvol_edit_insert(&mut self, ch: char) {
        if let Some((_, value)) = self.subvol_edit.as_mut() {
            if !ch.is_control() {
                value.push(ch);
            }
        }
    }

    pub fn subvol_edit_backspace(&mut self) {
        if let Some((_, value)) = self.subvol_edit.as_mut() {
            value.pop();
        }
    }

    pub fn subvol_cancel_edit(&mut self) {
        self.subvol_edit = None;
    }

    pub fn subvol_apply_edit(&mut self) -> std::result::Result<(), String> {
        let Some(i) = self.subvol_target else {
            return Ok(());
        };
        let Some((field, value)) = self.subvol_edit.take() else {
            return Ok(());
        };
        let value = value.trim().to_string();
        if value.is_empty() {
            return Err("value cannot be empty".to_string());
        }
        let Some(sub) = self.state.volumes[i].subvolumes.get_mut(self.subvol_sel) else {
            return Ok(());
        };
        match field {
            SubvolField::Name => {
                if !value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
                    return Err("name: letters, digits, _ and - only".to_string());
                }
                sub.name = value;
            }
            SubvolField::Mount => {
                validate_mountpoint(&value)?;
                sub.mountpoint = value;
            }
        }
        Ok(())
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
            Step::Users => {
                self.user_sel = self.user_sel.min(self.state.users.len().saturating_sub(1));
                self.user_edit = None;
                self.group_cursor = None;
            }
            Step::Efi => {
                self.cursor = match self.state.esp_size_mib {
                    0..=512 => 0,
                    513..=1024 => 1,
                    _ => 2,
                }
            }
            Step::Storage => {
                // The single disk editor: discover disks, then seed the pool with
                // whatever is already selected (or the first installable disk).
                self.discover_disks();
                if self.disk_selected.is_empty() {
                    for disk in self.state.disks.iter() {
                        self.disk_selected.insert(disk.path.clone());
                    }
                    if self.disk_selected.is_empty() {
                        if let Some(first) = self.installable_disks().first() {
                            self.disk_selected.insert(first.path.clone());
                        }
                    }
                }
                self.apply_disk_selection();
                self.disk_stage = DiskStage::Disks;
                self.disk_cursor = 0;
                self.pool_sel = 0;
                self.vol_sel = 0;
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
        // Grow the fill volume (root by default) to occupy the selected disk.
        self.state.fit_volumes_to_disk();
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

    #[allow(dead_code)]
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
                    fs: crate::install::state::VolumeFs::Btrfs,
                    subvolumes: Vec::new(),
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
                    self.state.disk_slices.remove(&path);
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
        if let Some(slices) = self.state.disk_slices.remove(old) {
            self.state.disk_slices.insert(new.to_string(), slices);
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
            Step::Users => {
                for user in &self.state.users {
                    validate_username(&user.name)?;
                }
                let mut seen = std::collections::BTreeSet::new();
                for user in &self.state.users {
                    if !seen.insert(user.name.clone()) {
                        return Err(format!("duplicate username: {}", user.name));
                    }
                }
                self.state.sync_primary_user();
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

    /// Passwords are now hashed per user as they are entered; this just mirrors
    /// the primary account into the legacy scalar fields before install.
    pub fn commit_password(&mut self) -> Result<(), String> {
        self.state.sync_primary_user();
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
        f.state.disk_slices.insert(
            "/dev/sda".into(),
            vec![crate::install::state::DiskSlice {
                pool: DEFAULT_STORAGE_POOL_NAME.into(),
                size_gib: 1000,
            }],
        );
        // Seed a "home" volume so there is a distinct fill target to draw from.
        f.state
            .volumes
            .push(crate::install::state::Volume::filesystem("home", "/home", 32).unwrap());
        f.state
            .set_volume_group_for_volume("home", DEFAULT_STORAGE_POOL_NAME);
        f.state.fit_volumes_to_disk();

        f.pool_enter();
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
        f.pool_enter();
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
            Step::Storage,
            Step::Overwrite,
            Step::NetworkCleanup,
            Step::BinEnsure,
            Step::Users,
            Step::Review,
            Step::Confirm,
        ] {
            assert!(steps.contains(&s), "missing step {s:?}");
        }
        // LVM/LUKS decided before the disk editor; accounts come last.
        let idx = |s: Step| steps.iter().position(|x| *x == s).unwrap();
        assert!(idx(Step::Lvm) < idx(Step::Storage), "LVM decided before disk editor");
        assert!(idx(Step::Encrypt) < idx(Step::Storage), "encryption decided before disk editor");
        assert!(idx(Step::Users) > idx(Step::Storage), "user accounts come last");
        // Disk selection + EFI are folded into the single Storage editor now.
        assert!(!steps.contains(&Step::Disks));
        assert!(!steps.contains(&Step::Efi));
    }

    #[test]
    fn users_editor_add_remove_and_groups() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Users);
        let n = f.user_count();
        f.users_add();
        assert_eq!(f.user_count(), n + 1);
        // toggle a group off then on for the new user
        let g = "corner";
        let had = f.user_has_group(g);
        f.group_begin();
        // move cursor to `corner`
        let idx = crate::install::state::AVAILABLE_GROUPS
            .iter()
            .position(|x| *x == g)
            .unwrap();
        f.group_cursor = Some(idx);
        f.group_toggle();
        assert_ne!(f.user_has_group(g), had);
        f.group_close();
        f.users_delete();
        assert_eq!(f.user_count(), n);
    }

    #[test]
    fn typing_a_size_sets_the_partition_exactly() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.goto_pools();
        f.pool_enter(); // partitions page
        f.vol_sel = 0;
        f.size_begin(Some('2'));
        f.size_insert('5');
        f.size_insert('6');
        f.size_apply();
        let i = f.selected_volume_index().unwrap();
        assert_eq!(f.state.volumes[i].size_gib, 256);
    }

    #[test]
    fn new_partition_starts_at_one_gib() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.goto_pools();
        f.pool_enter();
        f.disk_add();
        let i = f.selected_volume_index().unwrap();
        assert_eq!(f.state.volumes[i].size_gib, 1);
    }

    #[test]
    fn typing_a_size_resizes_the_pool_slice() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.goto_pools();
        f.pool_sel = 0;
        let pool = f.selected_pool_name().unwrap();
        // Type an exact pool capacity smaller than the whole disk.
        f.size_begin(Some('1'));
        f.size_insert('0');
        f.size_insert('0');
        f.size_apply();
        assert_eq!(f.state.pool_capacity_gib(&pool), 100);
    }

    #[test]
    fn storage_editor_cycles_per_volume_filesystem() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.pool_enter();
        let i = f.selected_volume_index().unwrap();
        assert_eq!(f.state.volumes[i].fs, VolumeFs::Btrfs);
        f.disk_cycle_fs();
        assert_eq!(f.state.volumes[i].fs, VolumeFs::Ext4);
        // cycling to swap flips the mountpoint kind to swap.
        f.disk_cycle_fs(); // xfs
        f.disk_cycle_fs(); // swap
        assert_eq!(f.state.volumes[i].fs, VolumeFs::Swap);
        assert!(matches!(f.state.volumes[i].mountpoint, Mountpoint::Swap));
    }

    #[test]
    fn subvolume_editor_only_opens_for_btrfs_and_adds_subvolumes() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.pool_enter();
        let i = f.selected_volume_index().unwrap();
        // btrfs by default → sub-editor opens and can add a subvolume.
        f.subvol_open();
        assert_eq!(f.subvol_target, Some(i));
        f.subvol_add();
        assert_eq!(f.state.volumes[i].subvolumes.len(), 1);
        f.subvol_close();
        assert!(f.subvol_target.is_none());
        // ext4 → no subvolumes, and existing ones are dropped.
        f.disk_cycle_fs();
        assert_eq!(f.state.volumes[i].fs, VolumeFs::Ext4);
        assert!(f.state.volumes[i].subvolumes.is_empty());
        f.subvol_open();
        assert!(f.subvol_target.is_none());
    }

    #[test]
    fn storage_editor_renames_and_remounts_a_partition() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.pool_enter();
        // rename the partition
        f.disk_begin_edit(PartField::Name);
        while f.disk_rename.as_deref().map(|s| !s.is_empty()).unwrap_or(false) {
            f.disk_rename_backspace();
        }
        for ch in "data".chars() {
            f.disk_rename_insert(ch);
        }
        f.disk_apply_rename();
        assert!(f.state.volumes.iter().any(|v| v.name == "data"));
        // change its mountpoint
        f.disk_begin_edit(PartField::Mount);
        while f.disk_rename.as_deref().map(|s| !s.is_empty()).unwrap_or(false) {
            f.disk_rename_backspace();
        }
        for ch in "/srv".chars() {
            f.disk_rename_insert(ch);
        }
        f.disk_apply_rename();
        let i = f.selected_volume_index().unwrap();
        assert_eq!(f.state.volumes[i].mountpoint.label(), "/srv");
    }

    #[test]
    fn moving_a_slice_to_another_pool_reassigns_capacity() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.goto_disks();
        // Add a second pool, then move the disk's slice into it.
        f.pool_add();
        let second = f.selected_pool_name().unwrap();
        let cap_before = f.state.pool_capacity_gib("pool");
        assert!(cap_before > 0);
        f.disk_cursor = 0;
        // Cycle the slice's pool until it lands on the new pool.
        for _ in 0..f.state.volume_groups.len() {
            if f.selected_slice()
                .and_then(|(p, i)| f.state.slices_for_disk(&p).get(i).map(|s| s.pool.clone()))
                == Some(second.clone())
            {
                break;
            }
            f.slice_cycle_pool();
        }
        assert_eq!(f.state.pool_capacity_gib("pool"), 0);
        assert_eq!(f.state.pool_capacity_gib(&second), cap_before);
    }

    #[test]
    fn splitting_a_slice_creates_a_second_slice_on_the_disk() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.goto_disks();
        let (path, _) = f.selected_slice().unwrap();
        // A whole-disk slice shrinks to make room, then split in half.
        f.slice_resize(-200);
        assert!(f.state.disk_free_gib(&path) > 0);
        let before = f.state.slices_for_disk(&path).len();
        f.slice_split();
        assert_eq!(f.state.slices_for_disk(&path).len(), before + 1);
        // A disk always keeps at least one slice.
        f.slice_delete();
        f.slice_delete();
        assert!(!f.state.slices_for_disk(&path).is_empty());
    }

    #[test]
    fn storage_step_is_followed_by_overwrite_confirmation() {
        let mut f = flow();
        f.cursor = 0;
        walk_to(&mut f, Step::Storage);
        f.advance();
        assert_eq!(f.current(), Step::Overwrite);
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
        // The minimal default layout is a single root volume that grows to fill
        // the selected disk; nothing about swap/home/nix is pre-decided.
        let root = f
            .state
            .volumes
            .iter()
            .find(|volume| matches!(&volume.mountpoint, Mountpoint::Path(p) if p == "/"))
            .expect("root volume exists");
        assert!(root.size_gib > 400);
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
        // Seed an over-capacity plan: two volumes summing past the disk size.
        f.state.volumes = vec![
            crate::install::state::Volume::filesystem("root", "/", 80).unwrap(),
            crate::install::state::Volume::filesystem("home", "/home", 80).unwrap(),
        ];
        let names: Vec<String> = f.state.volumes.iter().map(|v| v.name.clone()).collect();
        for name in names {
            f.state
                .set_volume_group_for_volume(&name, DEFAULT_STORAGE_POOL_NAME);
        }
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
