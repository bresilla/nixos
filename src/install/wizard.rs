use crate::install::confirm::DestructiveConfirmation;
use crate::install::preflight::PreflightReport;
use crate::install::state::{InstallState, InstallStep, Mountpoint, Volume};

#[derive(Debug, Clone)]
pub struct InstallWizard {
    pub state: InstallState,
    pub status: String,
    pub target_field: TargetField,
    pub disk_field: DiskField,
    pub selected_disk: usize,
    pub selected_pool: usize,
    pub volume_field: VolumeField,
    pub selected_volume: usize,
    pub confirm_armed: bool,
    pub confirm_input: String,
    pub preflight: Option<PreflightReport>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetField {
    Scope,
    Remote,
    Hostname,
    User,
    Mountpoint,
    Dotfiles,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskField {
    Select,
    Role,
    Pool,
    Path,
    Size,
    Mode,
    Filesystem,
    Encrypt,
    Overwrite,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VolumeField {
    Name,
    Mountpoint,
    Pool,
    Size,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WizardCommand {
    Next,
    Back,
    SelectNext,
    SelectPrevious,
    Toggle,
    Increase,
    Decrease,
    SelectDiskNext,
    SelectDiskPrevious,
    Insert(char),
    Backspace,
    Quit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WizardOutcome {
    Continue,
    Quit,
    ReadyToInstall,
}

impl InstallWizard {
    pub fn new(state: InstallState) -> Self {
        Self {
            state,
            status: "review target, then press enter".to_string(),
            target_field: TargetField::Scope,
            disk_field: DiskField::Select,
            selected_disk: 0,
            selected_pool: 0,
            volume_field: VolumeField::Name,
            selected_volume: 0,
            confirm_armed: false,
            confirm_input: String::new(),
            preflight: None,
        }
    }

    pub fn handle(&mut self, command: WizardCommand) -> WizardOutcome {
        match command {
            WizardCommand::Next => self.next(),
            WizardCommand::Back => {
                self.back();
                WizardOutcome::Continue
            }
            WizardCommand::SelectNext => {
                self.select_next();
                WizardOutcome::Continue
            }
            WizardCommand::SelectPrevious => {
                self.select_previous();
                WizardOutcome::Continue
            }
            WizardCommand::Toggle => {
                self.toggle();
                WizardOutcome::Continue
            }
            WizardCommand::Increase => {
                self.adjust_size(1);
                WizardOutcome::Continue
            }
            WizardCommand::Decrease => {
                self.adjust_size(-1);
                WizardOutcome::Continue
            }
            WizardCommand::SelectDiskNext => {
                self.select_disk_next();
                WizardOutcome::Continue
            }
            WizardCommand::SelectDiskPrevious => {
                self.select_disk_previous();
                WizardOutcome::Continue
            }
            WizardCommand::Insert(ch) => {
                self.insert(ch);
                WizardOutcome::Continue
            }
            WizardCommand::Backspace => {
                self.backspace();
                WizardOutcome::Continue
            }
            WizardCommand::Quit => WizardOutcome::Quit,
        }
    }

    fn next(&mut self) -> WizardOutcome {
        if self.state.current_step == InstallStep::Confirm
            && !self.preflight.as_ref().is_some_and(PreflightReport::pass)
        {
            self.status = "press space to run preflight first".to_string();
            return WizardOutcome::Continue;
        }

        if self.state.current_step == InstallStep::Confirm && !self.confirm_armed {
            self.refresh_confirm_armed();
            if !self.confirm_armed {
                self.status = "type the exact wipe phrase to arm install".to_string();
                return WizardOutcome::Continue;
            }
        }

        if self.state.current_step == InstallStep::Confirm && !self.confirm_armed {
            return WizardOutcome::Continue;
        }

        if self.state.current_step == InstallStep::Confirm && self.confirm_armed {
            self.state.current_step = InstallStep::Install;
            self.status = "starting installer".to_string();
            return WizardOutcome::ReadyToInstall;
        }

        if let Some(step) = step_after(self.state.current_step) {
            self.state.current_step = step;
            self.status = status_for_step(step).to_string();
        }
        WizardOutcome::Continue
    }

    fn back(&mut self) {
        if let Some(step) = step_before(self.state.current_step) {
            self.state.current_step = step;
            self.status = status_for_step(step).to_string();
        }
    }

    fn select_next(&mut self) {
        match self.state.current_step {
            InstallStep::Target => {
                self.target_field = self.target_field.next();
                self.status = format!("editing {}", self.target_field.title());
            }
            InstallStep::Disks => {
                self.disk_field = self.disk_field.next();
                self.status = format!("editing disk {}", self.disk_field.title());
            }
            InstallStep::Pools => {
                self.select_pool_next();
            }
            InstallStep::Volumes => {
                let len = self.state.volumes.len().max(1);
                self.selected_volume = (self.selected_volume + 1) % len;
                self.status = format!("selected volume {}", self.selected_volume + 1);
            }
            InstallStep::Role => {
                self.state.role = self.state.role.next();
                self.status = format!("role set to {}", self.state.role.title());
            }
            InstallStep::Secrets => {
                self.state.secrets_ready = !self.state.secrets_ready;
                self.status = if self.state.secrets_ready {
                    "secrets marked ready for this draft".to_string()
                } else {
                    "secrets marked locked".to_string()
                };
            }
            step => {
                self.status = format!("{} editing is not implemented yet", step.title());
            }
        }
    }

    fn select_previous(&mut self) {
        match self.state.current_step {
            InstallStep::Target => {
                self.target_field = self.target_field.previous();
                self.status = format!("editing {}", self.target_field.title());
            }
            InstallStep::Disks => {
                self.disk_field = self.disk_field.previous();
                self.status = format!("editing disk {}", self.disk_field.title());
            }
            InstallStep::Pools => {
                self.select_pool_previous();
            }
            InstallStep::Volumes => {
                let len = self.state.volumes.len();
                if len > 0 {
                    self.selected_volume = if self.selected_volume == 0 {
                        len - 1
                    } else {
                        self.selected_volume - 1
                    };
                    self.status = format!("selected volume {}", self.selected_volume + 1);
                }
            }
            InstallStep::Role => {
                self.state.role = self.state.role.previous();
                self.status = format!("role set to {}", self.state.role.title());
            }
            InstallStep::Secrets => self.select_next(),
            step => {
                self.status = format!("{} editing is not implemented yet", step.title());
            }
        }
    }

    fn insert(&mut self, ch: char) {
        match self.state.current_step {
            InstallStep::Target => {
                if !valid_target_char(ch) {
                    return;
                }
                match self.target_field {
                    TargetField::Scope => return,
                    TargetField::Remote => self.state.remote.push(ch),
                    TargetField::Hostname => self.state.hostname.push(ch),
                    TargetField::User => self.state.install_user.push(ch),
                    TargetField::Mountpoint => self.state.mountpoint.push(ch),
                    TargetField::Dotfiles => {
                        let repo = self.state.dotfiles_repo.get_or_insert_with(String::new);
                        repo.push(ch);
                    }
                }
                self.status = format!("editing {}", self.target_field.title());
            }
            InstallStep::Disks => {
                let field = self.disk_field;
                let mut changed_disk = false;
                if field == DiskField::Pool {
                    self.rename_current_disk_volume_group_with_char(ch);
                    return;
                } else if let Some(disk) = self.current_selected_disk_mut() {
                    match field {
                        DiskField::Path if valid_disk_char(ch) => {
                            disk.path.push(ch);
                            changed_disk = true;
                        }
                        DiskField::Size if ch.is_ascii_digit() => {
                            let mut value = disk.size_gib.to_string();
                            value.push(ch);
                            if let Ok(parsed) = value.parse::<u64>() {
                                disk.size_gib = parsed.min(100_000);
                                changed_disk = true;
                            }
                        }
                        _ => {}
                    }
                }
                if changed_disk {
                    self.state.normalize_disk_roles();
                }
                self.status = format!("editing disk {}", self.disk_field.title());
            }
            InstallStep::Volumes => {
                let field = self.volume_field;
                if field == VolumeField::Pool {
                    self.rename_current_volume_group_with_char(ch);
                    return;
                } else if let Some(volume) = self.selected_volume_mut() {
                    match field {
                        VolumeField::Name if valid_attr_char(ch) => volume.name.push(ch),
                        VolumeField::Mountpoint if valid_mount_char(ch) => {
                            if let Mountpoint::Path(path) = &mut volume.mountpoint {
                                path.push(ch);
                            }
                        }
                        VolumeField::Size if ch.is_ascii_digit() => {
                            let mut value = volume.size_gib.to_string();
                            value.push(ch);
                            if let Ok(parsed) = value.parse::<u64>() {
                                volume.size_gib = parsed.min(10_000);
                            }
                        }
                        _ => {}
                    }
                }
                self.status = format!("editing volume {}", self.volume_field.title());
            }
            InstallStep::Confirm => {
                if self.preflight.as_ref().is_some_and(PreflightReport::pass) {
                    self.confirm_input.push(ch);
                    self.refresh_confirm_armed();
                    self.status = if self.confirm_armed {
                        "confirmation matched; press enter to run".to_string()
                    } else {
                        "typing confirmation phrase".to_string()
                    };
                } else {
                    self.status = "press space to run preflight first".to_string();
                }
            }
            InstallStep::Pools => {
                self.rename_selected_volume_group_with_char(ch);
            }
            _ => {}
        }
    }

    fn toggle(&mut self) {
        match self.state.current_step {
            InstallStep::Target if self.target_field == TargetField::Scope => {
                self.state.scope = self.state.scope.next();
                self.status = format!("scope set to {}", self.state.scope.title());
            }
            InstallStep::Role => {
                self.state.allow_ssh = !self.state.allow_ssh;
                self.status = if self.state.allow_ssh {
                    "ssh enabled for installed system".to_string()
                } else {
                    "ssh disabled for installed system".to_string()
                };
            }
            InstallStep::Disks => {
                if self.disk_field == DiskField::Overwrite {
                    self.state.overwrite_existing_storage = !self.state.overwrite_existing_storage;
                    self.status = if self.state.overwrite_existing_storage {
                        "overwrite existing install storage enabled".to_string()
                    } else {
                        "overwrite existing install storage disabled".to_string()
                    };
                } else if self.disk_field == DiskField::Role {
                    self.cycle_current_disk_role();
                } else if self.disk_field == DiskField::Pool {
                    self.cycle_current_disk_volume_group();
                } else if self.disk_field == DiskField::Mode {
                    self.state.storage_mode = self.state.storage_mode.next_supported();
                    self.status =
                        format!("storage mode set to {}", self.state.storage_mode.title());
                } else if self.disk_field == DiskField::Filesystem {
                    self.state.filesystem = self.state.filesystem.next();
                    self.status = format!("filesystem set to {}", self.state.filesystem.title());
                } else if self.disk_field == DiskField::Encrypt {
                    self.state.encrypt = !self.state.encrypt;
                    self.status = if self.state.encrypt {
                        "LUKS encryption enabled".to_string()
                    } else {
                        "LUKS encryption disabled".to_string()
                    };
                } else {
                    self.toggle_current_disk_selection();
                }
            }
            InstallStep::Pools => {
                self.create_volume_group_from_pool_step();
            }
            InstallStep::Volumes => {
                if self.volume_field == VolumeField::Pool {
                    self.cycle_current_volume_group(1);
                } else {
                    self.volume_field = self.volume_field.next();
                    self.status = format!("editing volume {}", self.volume_field.title());
                }
            }
            InstallStep::Secrets => {
                self.state.secrets_ready = !self.state.secrets_ready;
                self.status = if self.state.secrets_ready {
                    "secrets marked ready for this draft".to_string()
                } else {
                    "secrets marked locked".to_string()
                };
            }
            InstallStep::Confirm => {
                if self.preflight.as_ref().is_some_and(PreflightReport::pass) {
                    self.refresh_confirm_armed();
                    self.status = if self.confirm_armed {
                        "confirmation matched; press enter to run".to_string()
                    } else {
                        "type the exact wipe phrase to arm install".to_string()
                    };
                } else {
                    self.status = "preflight has not passed yet".to_string();
                }
            }
            step => {
                self.status = format!("{} has no toggle action", step.title());
            }
        }
    }

    fn backspace(&mut self) {
        match self.state.current_step {
            InstallStep::Target => {
                match self.target_field {
                    TargetField::Scope => return,
                    TargetField::Remote => {
                        self.state.remote.pop();
                    }
                    TargetField::Hostname => {
                        self.state.hostname.pop();
                    }
                    TargetField::User => {
                        self.state.install_user.pop();
                    }
                    TargetField::Mountpoint => {
                        self.state.mountpoint.pop();
                    }
                    TargetField::Dotfiles => {
                        if let Some(repo) = self.state.dotfiles_repo.as_mut() {
                            repo.pop();
                            if matches!(repo.as_str(), "" | "skip" | "none" | "no") {
                                self.state.dotfiles_repo = None;
                            }
                        }
                    }
                }
                self.status = format!("editing {}", self.target_field.title());
            }
            InstallStep::Disks => {
                let field = self.disk_field;
                let mut changed_disk = false;
                if field == DiskField::Pool {
                    self.backspace_current_disk_volume_group();
                    return;
                } else if let Some(disk) = self.current_selected_disk_mut() {
                    match field {
                        DiskField::Path => {
                            disk.path.pop();
                            changed_disk = true;
                        }
                        DiskField::Size => {
                            disk.size_gib /= 10;
                            changed_disk = true;
                        }
                        DiskField::Select
                        | DiskField::Role
                        | DiskField::Pool
                        | DiskField::Mode
                        | DiskField::Filesystem
                        | DiskField::Encrypt
                        | DiskField::Overwrite => {}
                    }
                }
                if changed_disk {
                    self.state.normalize_disk_roles();
                }
                self.status = format!("editing disk {}", self.disk_field.title());
            }
            InstallStep::Pools => {
                self.backspace_selected_volume_group();
            }
            InstallStep::Volumes => {
                let field = self.volume_field;
                if field == VolumeField::Pool {
                    self.backspace_current_volume_group();
                    return;
                } else if let Some(volume) = self.selected_volume_mut() {
                    match field {
                        VolumeField::Name => {
                            volume.name.pop();
                        }
                        VolumeField::Mountpoint => {
                            if let Mountpoint::Path(path) = &mut volume.mountpoint {
                                path.pop();
                                if path.is_empty() {
                                    path.push('/');
                                }
                            }
                        }
                        VolumeField::Pool => {}
                        VolumeField::Size => volume.size_gib /= 10,
                    }
                }
                self.status = format!("editing volume {}", self.volume_field.title());
            }
            InstallStep::Confirm => {
                self.confirm_input.pop();
                self.refresh_confirm_armed();
                self.status = if self.confirm_armed {
                    "confirmation matched; press enter to run".to_string()
                } else {
                    "typing confirmation phrase".to_string()
                };
            }
            _ => {}
        }
    }

    fn adjust_size(&mut self, delta: i64) {
        let step = if delta > 0 { 8 } else { -8 };
        match self.state.current_step {
            InstallStep::Disks => {
                if self.disk_field == DiskField::Pool {
                    if delta.is_negative() {
                        self.delete_current_disk_volume_group();
                    } else {
                        self.create_volume_group_for_current_disk();
                    }
                } else if let Some(disk) = self.current_selected_disk_mut() {
                    disk.size_gib = apply_delta(disk.size_gib, step);
                    self.status = format!("disk size set to {}G", disk.size_gib);
                    self.state.normalize_disk_roles();
                }
            }
            InstallStep::Volumes => {
                if self.volume_field == VolumeField::Pool {
                    if delta.is_negative() {
                        self.delete_current_volume_group();
                    } else {
                        self.create_volume_group_for_current_volume();
                    }
                } else if let Some(volume) = self.selected_volume_mut() {
                    volume.size_gib = apply_delta(volume.size_gib, step);
                    self.status = format!("{} size set to {}G", volume.name, volume.size_gib);
                }
            }
            InstallStep::Pools => {
                if delta.is_negative() {
                    self.delete_selected_volume_group();
                } else {
                    self.create_volume_group_from_pool_step();
                }
            }
            _ => {}
        }
    }

    fn selected_volume_mut(&mut self) -> Option<&mut Volume> {
        self.state.volumes.get_mut(self.selected_volume)
    }

    fn select_pool_next(&mut self) {
        let len = self.state.volume_groups.len().max(1);
        self.selected_pool = (self.selected_pool + 1) % len;
        self.status = format!("selected pool {}", self.selected_pool + 1);
    }

    fn select_pool_previous(&mut self) {
        let len = self.state.volume_groups.len();
        if len > 0 {
            self.selected_pool = if self.selected_pool == 0 {
                len - 1
            } else {
                self.selected_pool - 1
            };
            self.status = format!("selected pool {}", self.selected_pool + 1);
        }
    }

    fn select_disk_next(&mut self) {
        let len = self.visible_disks_len();
        if len > 0 {
            self.selected_disk = (self.selected_disk + 1) % len;
            self.status = format!("selected disk {}", self.selected_disk + 1);
        }
    }

    fn select_disk_previous(&mut self) {
        let len = self.visible_disks_len();
        if len > 0 {
            self.selected_disk = if self.selected_disk == 0 {
                len - 1
            } else {
                self.selected_disk - 1
            };
            self.status = format!("selected disk {}", self.selected_disk + 1);
        }
    }

    fn visible_disks_len(&self) -> usize {
        self.state.visible_disks().len()
    }

    fn current_visible_disk(&self) -> Option<&crate::install::state::DiskChoice> {
        self.state.visible_disks().get(self.selected_disk)
    }

    fn current_selected_disk_mut(&mut self) -> Option<&mut crate::install::state::DiskChoice> {
        if self.state.discovered_disks.is_empty() {
            return self.state.disks.get_mut(self.selected_disk);
        }
        self.state.discovered_disks.get_mut(self.selected_disk)
    }

    fn toggle_current_disk_selection(&mut self) {
        let Some(disk) = self.current_visible_disk().cloned() else {
            self.status = "no disk selected".to_string();
            return;
        };

        let role = self.state.disk_role_for_path(&disk.path);
        if matches!(
            role,
            crate::install::state::DiskRole::System | crate::install::state::DiskRole::PoolMember
        ) {
            self.state
                .set_disk_role(&disk.path, crate::install::state::DiskRole::Ignore);
            self.status = format!("ignored install disk {}", disk.path);
        } else {
            self.state
                .set_disk_role(&disk.path, crate::install::state::DiskRole::PoolMember);
            self.status = format!(
                "{} set to {}",
                disk.path,
                self.state.disk_role_for_path(&disk.path).title()
            );
        }
    }

    fn cycle_current_disk_role(&mut self) {
        let Some(disk) = self.current_visible_disk().cloned() else {
            self.status = "no disk selected".to_string();
            return;
        };
        let next_role = self.state.disk_role_for_path(&disk.path).next();
        self.state.set_disk_role(&disk.path, next_role);
        self.status = format!(
            "{} role set to {}",
            disk.path,
            self.state.disk_role_for_path(&disk.path).title()
        );
    }

    fn cycle_current_disk_volume_group(&mut self) {
        let Some(disk) = self.current_visible_disk().cloned() else {
            self.status = "no disk selected".to_string();
            return;
        };
        if !matches!(
            self.state.disk_role_for_path(&disk.path),
            crate::install::state::DiskRole::System | crate::install::state::DiskRole::PoolMember
        ) {
            self.status = format!("{} is not an install disk", disk.path);
            return;
        }
        let current = self
            .state
            .disk_volume_group_for_path(&disk.path)
            .unwrap_or_else(|| self.state.default_volume_group_name())
            .to_string();
        let next = self.next_volume_group_name(&current, 1);
        self.state.set_disk_volume_group(&disk.path, &next);
        self.status = format!("{} pool set to {}", disk.path, next);
    }

    fn cycle_current_volume_group(&mut self, delta: i64) {
        let Some(volume) = self.state.volumes.get(self.selected_volume).cloned() else {
            self.status = "no volume selected".to_string();
            return;
        };
        let current = self.state.volume_group_for_volume(&volume.name).to_string();
        let next = self.next_volume_group_name(&current, delta);
        self.state.set_volume_group_for_volume(&volume.name, &next);
        self.status = format!("{} pool set to {}", volume.name, next);
    }

    fn create_volume_group_for_current_disk(&mut self) {
        let Some(disk) = self.current_visible_disk().cloned() else {
            self.status = "no disk selected".to_string();
            return;
        };
        if !matches!(
            self.state.disk_role_for_path(&disk.path),
            crate::install::state::DiskRole::System | crate::install::state::DiskRole::PoolMember
        ) {
            self.status = format!("{} is not an install disk", disk.path);
            return;
        }
        let name = self.state.create_next_volume_group();
        self.state.set_disk_volume_group(&disk.path, &name);
        self.status = format!("created pool {name} for {}", disk.path);
    }

    fn create_volume_group_for_current_volume(&mut self) {
        let Some(volume) = self.state.volumes.get(self.selected_volume).cloned() else {
            self.status = "no volume selected".to_string();
            return;
        };
        let name = self.state.create_next_volume_group();
        self.state.set_volume_group_for_volume(&volume.name, &name);
        self.status = format!("created pool {name} for {}", volume.name);
    }

    fn create_volume_group_from_pool_step(&mut self) {
        let name = self.state.create_next_volume_group();
        self.selected_pool = self
            .state
            .volume_groups
            .iter()
            .position(|group| group.name == name)
            .unwrap_or(self.selected_pool);
        self.status = format!("created pool {name}");
    }

    fn delete_current_disk_volume_group(&mut self) {
        let Some(pool) = self.current_disk_volume_group_name() else {
            self.status = "selected disk has no pool".to_string();
            return;
        };
        self.delete_volume_group(&pool);
    }

    fn delete_current_volume_group(&mut self) {
        let Some(pool) = self.current_volume_group_name() else {
            self.status = "selected volume has no pool".to_string();
            return;
        };
        self.delete_volume_group(&pool);
    }

    fn delete_selected_volume_group(&mut self) {
        let Some(pool) = self.selected_volume_group_name() else {
            self.status = "no pool selected".to_string();
            return;
        };
        self.delete_volume_group(&pool);
        self.selected_pool = self
            .selected_pool
            .min(self.state.volume_groups.len().saturating_sub(1));
    }

    fn delete_volume_group(&mut self, pool: &str) {
        match self.state.delete_volume_group_reassigning_to_default(pool) {
            Ok(()) => self.status = format!("deleted pool {pool}; assignments moved to default"),
            Err(err) => self.status = err,
        }
    }

    fn rename_current_disk_volume_group_with_char(&mut self, ch: char) {
        if !valid_attr_char(ch) {
            return;
        }
        let Some(pool) = self.current_disk_volume_group_name() else {
            self.status = "selected disk has no pool".to_string();
            return;
        };
        let mut renamed = pool.clone();
        renamed.push(ch);
        self.rename_volume_group(&pool, &renamed);
    }

    fn rename_current_volume_group_with_char(&mut self, ch: char) {
        if !valid_attr_char(ch) {
            return;
        }
        let Some(pool) = self.current_volume_group_name() else {
            self.status = "selected volume has no pool".to_string();
            return;
        };
        let mut renamed = pool.clone();
        renamed.push(ch);
        self.rename_volume_group(&pool, &renamed);
    }

    fn rename_selected_volume_group_with_char(&mut self, ch: char) {
        if !valid_attr_char(ch) {
            return;
        }
        let Some(pool) = self.selected_volume_group_name() else {
            self.status = "no pool selected".to_string();
            return;
        };
        let mut renamed = pool.clone();
        renamed.push(ch);
        self.rename_volume_group(&pool, &renamed);
    }

    fn backspace_current_disk_volume_group(&mut self) {
        let Some(pool) = self.current_disk_volume_group_name() else {
            self.status = "selected disk has no pool".to_string();
            return;
        };
        self.backspace_volume_group(&pool);
    }

    fn backspace_current_volume_group(&mut self) {
        let Some(pool) = self.current_volume_group_name() else {
            self.status = "selected volume has no pool".to_string();
            return;
        };
        self.backspace_volume_group(&pool);
    }

    fn backspace_selected_volume_group(&mut self) {
        let Some(pool) = self.selected_volume_group_name() else {
            self.status = "no pool selected".to_string();
            return;
        };
        self.backspace_volume_group(&pool);
    }

    fn backspace_volume_group(&mut self, pool: &str) {
        let mut renamed = pool.to_string();
        renamed.pop();
        if renamed.is_empty() {
            self.status = "pool name cannot be empty".to_string();
            return;
        }
        self.rename_volume_group(pool, &renamed);
    }

    fn rename_volume_group(&mut self, old_name: &str, new_name: &str) {
        match self.state.rename_volume_group(old_name, new_name) {
            Ok(()) => self.status = format!("pool {old_name} renamed to {new_name}"),
            Err(err) => self.status = err,
        }
    }

    fn current_disk_volume_group_name(&self) -> Option<String> {
        let disk = self.current_visible_disk()?;
        self.state
            .disk_volume_group_for_path(&disk.path)
            .map(ToString::to_string)
    }

    fn current_volume_group_name(&self) -> Option<String> {
        let volume = self.state.volumes.get(self.selected_volume)?;
        Some(self.state.volume_group_for_volume(&volume.name).to_string())
    }

    fn selected_volume_group_name(&self) -> Option<String> {
        self.state
            .volume_groups
            .get(self.selected_pool)
            .map(|group| group.name.clone())
    }

    fn next_volume_group_name(&self, current: &str, delta: i64) -> String {
        let names = self
            .state
            .volume_groups
            .iter()
            .map(|group| group.name.as_str())
            .collect::<Vec<_>>();
        if names.is_empty() {
            return self.state.default_volume_group_name().to_string();
        }
        let index = names.iter().position(|name| *name == current).unwrap_or(0);
        let len = names.len();
        let next = if delta.is_negative() {
            index.checked_sub(1).unwrap_or(len - 1)
        } else {
            (index + 1) % len
        };
        names[next].to_string()
    }

    pub fn set_preflight(&mut self, report: PreflightReport) {
        let passed = report.pass();
        let failed_count = report.failed_count();
        self.preflight = Some(report);
        if passed {
            self.refresh_confirm_armed();
            self.status = if self.confirm_armed {
                "confirmation matched; press enter to run".to_string()
            } else {
                "preflight passed; type the wipe phrase".to_string()
            };
        } else {
            self.status = format!("preflight failed: {failed_count} check(s)");
            self.confirm_armed = false;
        }
        if !passed {
            self.confirm_armed = false;
        }
    }

    pub fn confirmation(&self) -> DestructiveConfirmation {
        DestructiveConfirmation::from_state(&self.state)
    }

    fn refresh_confirm_armed(&mut self) {
        self.confirm_armed = self.preflight.as_ref().is_some_and(PreflightReport::pass)
            && self.confirmation().matches(&self.confirm_input);
    }
}

impl TargetField {
    pub fn title(self) -> &'static str {
        match self {
            TargetField::Scope => "scope",
            TargetField::Remote => "remote",
            TargetField::Hostname => "hostname",
            TargetField::User => "user",
            TargetField::Mountpoint => "mountpoint",
            TargetField::Dotfiles => "dotfiles",
        }
    }

    fn next(self) -> Self {
        match self {
            TargetField::Scope => TargetField::Remote,
            TargetField::Remote => TargetField::Hostname,
            TargetField::Hostname => TargetField::User,
            TargetField::User => TargetField::Mountpoint,
            TargetField::Mountpoint => TargetField::Dotfiles,
            TargetField::Dotfiles => TargetField::Scope,
        }
    }

    fn previous(self) -> Self {
        self.next()
    }
}

impl DiskField {
    pub fn title(self) -> &'static str {
        match self {
            DiskField::Select => "select",
            DiskField::Role => "role",
            DiskField::Pool => "pool",
            DiskField::Path => "path",
            DiskField::Size => "size",
            DiskField::Mode => "mode",
            DiskField::Filesystem => "filesystem",
            DiskField::Encrypt => "encrypt",
            DiskField::Overwrite => "overwrite",
        }
    }

    fn next(self) -> Self {
        match self {
            DiskField::Select => DiskField::Role,
            DiskField::Role => DiskField::Pool,
            DiskField::Pool => DiskField::Path,
            DiskField::Path => DiskField::Size,
            DiskField::Size => DiskField::Mode,
            DiskField::Mode => DiskField::Filesystem,
            DiskField::Filesystem => DiskField::Encrypt,
            DiskField::Encrypt => DiskField::Overwrite,
            DiskField::Overwrite => DiskField::Select,
        }
    }

    fn previous(self) -> Self {
        match self {
            DiskField::Select => DiskField::Overwrite,
            DiskField::Role => DiskField::Select,
            DiskField::Pool => DiskField::Role,
            DiskField::Path => DiskField::Pool,
            DiskField::Size => DiskField::Path,
            DiskField::Mode => DiskField::Size,
            DiskField::Filesystem => DiskField::Mode,
            DiskField::Encrypt => DiskField::Filesystem,
            DiskField::Overwrite => DiskField::Encrypt,
        }
    }
}

impl VolumeField {
    pub fn title(self) -> &'static str {
        match self {
            VolumeField::Name => "name",
            VolumeField::Mountpoint => "mountpoint",
            VolumeField::Pool => "pool",
            VolumeField::Size => "size",
        }
    }

    fn next(self) -> Self {
        match self {
            VolumeField::Name => VolumeField::Mountpoint,
            VolumeField::Mountpoint => VolumeField::Pool,
            VolumeField::Pool => VolumeField::Size,
            VolumeField::Size => VolumeField::Name,
        }
    }
}

fn valid_target_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || matches!(ch, '@' | '.' | '-' | '_' | '/' | ':' | '+')
}

fn valid_disk_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '-' | '_')
}

fn valid_mount_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '-' | '_')
}

fn valid_attr_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_'
}

fn apply_delta(value: u64, delta: i64) -> u64 {
    if delta.is_negative() {
        value.saturating_sub(delta.unsigned_abs()).max(1)
    } else {
        value.saturating_add(delta as u64)
    }
}

fn step_after(step: InstallStep) -> Option<InstallStep> {
    let steps = InstallState::steps();
    let index = steps.iter().position(|candidate| candidate == &step)?;
    steps.get(index + 1).copied()
}

fn step_before(step: InstallStep) -> Option<InstallStep> {
    let steps = InstallState::steps();
    let index = steps.iter().position(|candidate| candidate == &step)?;
    index
        .checked_sub(1)
        .and_then(|previous| steps.get(previous).copied())
}

fn status_for_step(step: InstallStep) -> &'static str {
    match step {
        InstallStep::Target => "review target, then press enter",
        InstallStep::Role => "left/right changes role; space toggles ssh",
        InstallStep::Disks => {
            "up/down selects disk; left/right changes field; space toggles disk/role/pool/overwrite"
        }
        InstallStep::Pools => "up/down selects pool; +/- creates/deletes; type renames",
        InstallStep::Volumes => {
            "left/right selects volume; space changes field; +/- edits size or pool"
        }
        InstallStep::Secrets => "left/right toggles draft secret readiness",
        InstallStep::StoragePlan => "review storage plan; enter continues to confirmation",
        InstallStep::Confirm => "confirm screen will gate destructive actions",
        InstallStep::Install => "install execution is still delegated",
    }
}

#[cfg(test)]
mod tests {
    use super::{DiskField, InstallWizard, TargetField, VolumeField, WizardCommand, WizardOutcome};
    use crate::install::preflight::PreflightReport;
    use crate::install::state::{
        DiskChoice, Filesystem, InstallRole, InstallScope, InstallState, InstallStep, StorageMode,
    };

    #[test]
    fn next_and_back_move_between_steps() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        assert_eq!(wizard.state.current_step, InstallStep::Target);

        assert_eq!(wizard.handle(WizardCommand::Next), WizardOutcome::Continue);
        assert_eq!(wizard.state.current_step, InstallStep::Role);

        assert_eq!(wizard.handle(WizardCommand::Back), WizardOutcome::Continue);
        assert_eq!(wizard.state.current_step, InstallStep::Target);
    }

    #[test]
    fn storage_plan_step_sits_before_confirmation() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Secrets;

        assert_eq!(wizard.handle(WizardCommand::Next), WizardOutcome::Continue);
        assert_eq!(wizard.state.current_step, InstallStep::StoragePlan);

        assert_eq!(wizard.handle(WizardCommand::Next), WizardOutcome::Continue);
        assert_eq!(wizard.state.current_step, InstallStep::Confirm);

        assert_eq!(wizard.handle(WizardCommand::Back), WizardOutcome::Continue);
        assert_eq!(wizard.state.current_step, InstallStep::StoragePlan);
    }

    #[test]
    fn role_step_changes_role() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.handle(WizardCommand::Next);
        assert_eq!(wizard.state.current_step, InstallStep::Role);
        assert_eq!(wizard.state.role, InstallRole::Laptop);
        assert!(!wizard.state.allow_ssh);

        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.state.role, InstallRole::Server);

        wizard.handle(WizardCommand::SelectPrevious);
        assert_eq!(wizard.state.role, InstallRole::Laptop);
    }

    #[test]
    fn role_step_toggles_installed_system_ssh() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.handle(WizardCommand::Next);
        assert_eq!(wizard.state.current_step, InstallStep::Role);
        assert!(!wizard.state.allow_ssh);

        wizard.handle(WizardCommand::Toggle);
        assert!(wizard.state.allow_ssh);
        assert_eq!(wizard.status, "ssh enabled for installed system");

        wizard.handle(WizardCommand::Toggle);
        assert!(!wizard.state.allow_ssh);
        assert_eq!(wizard.status, "ssh disabled for installed system");
    }

    #[test]
    fn disk_step_toggles_storage_overwrite() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.handle(WizardCommand::Next);
        wizard.handle(WizardCommand::Next);
        assert_eq!(wizard.state.current_step, InstallStep::Disks);
        assert!(!wizard.state.overwrite_existing_storage);

        wizard.handle(WizardCommand::SelectPrevious);
        assert_eq!(wizard.disk_field, DiskField::Overwrite);
        wizard.handle(WizardCommand::Toggle);
        assert!(wizard.state.overwrite_existing_storage);
        assert_eq!(wizard.status, "overwrite existing install storage enabled");

        wizard.handle(WizardCommand::Toggle);
        assert!(!wizard.state.overwrite_existing_storage);
        assert_eq!(wizard.status, "overwrite existing install storage disabled");
    }

    #[test]
    fn disk_step_toggles_storage_mode() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Disks;
        assert_eq!(wizard.state.storage_mode, StorageMode::JoinedLvm);

        wizard.handle(WizardCommand::SelectPrevious);
        assert_eq!(wizard.disk_field, DiskField::Overwrite);
        wizard.handle(WizardCommand::SelectPrevious);
        assert_eq!(wizard.disk_field, DiskField::Encrypt);
        wizard.handle(WizardCommand::SelectPrevious);
        assert_eq!(wizard.disk_field, DiskField::Filesystem);
        wizard.handle(WizardCommand::SelectPrevious);
        assert_eq!(wizard.disk_field, DiskField::Mode);
        wizard.handle(WizardCommand::Toggle);

        assert_eq!(wizard.state.storage_mode, StorageMode::SingleDisk);
        assert_eq!(wizard.status, "storage mode set to single-disk");
    }

    #[test]
    fn disk_step_toggles_filesystem_and_encryption() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Disks;
        assert_eq!(wizard.state.filesystem, Filesystem::Btrfs);
        assert!(!wizard.state.encrypt);

        wizard.disk_field = DiskField::Filesystem;
        wizard.handle(WizardCommand::Toggle);
        assert_eq!(wizard.state.filesystem, Filesystem::Ext4);
        assert_eq!(wizard.status, "filesystem set to ext4");

        wizard.disk_field = DiskField::Encrypt;
        wizard.handle(WizardCommand::Toggle);
        assert!(wizard.state.encrypt);
        assert_eq!(wizard.status, "LUKS encryption enabled");
    }

    #[test]
    fn target_step_edits_remote_and_hostname() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.remote.clear();
        wizard.state.hostname.clear();
        assert_eq!(wizard.target_field, TargetField::Scope);
        wizard.handle(WizardCommand::Toggle);
        assert_eq!(wizard.state.scope, InstallScope::Local);
        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.target_field, TargetField::Remote);

        wizard.handle(WizardCommand::Insert('n'));
        wizard.handle(WizardCommand::Insert('x'));
        assert_eq!(wizard.state.remote, "nx");

        wizard.handle(WizardCommand::SelectNext);
        wizard.handle(WizardCommand::Insert('h'));
        wizard.handle(WizardCommand::Insert('1'));
        assert_eq!(wizard.state.hostname, "h1");

        wizard.handle(WizardCommand::Backspace);
        assert_eq!(wizard.state.hostname, "h");
    }

    #[test]
    fn target_step_rejects_spaces() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.remote.clear();
        wizard.handle(WizardCommand::SelectNext);

        wizard.handle(WizardCommand::Insert('x'));
        wizard.handle(WizardCommand::Insert(' '));
        assert_eq!(wizard.state.remote, "x");
    }

    #[test]
    fn secrets_step_can_toggle_ready_state() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Secrets;
        assert!(!wizard.state.secrets_ready);

        wizard.handle(WizardCommand::SelectNext);
        assert!(wizard.state.secrets_ready);
    }

    #[test]
    fn disk_step_edits_path_and_size() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Disks;
        wizard.state.disks[0].path.clear();

        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.disk_field, DiskField::Role);
        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.disk_field, DiskField::Pool);
        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.disk_field, DiskField::Path);
        wizard.handle(WizardCommand::Insert('/'));
        wizard.handle(WizardCommand::Insert('d'));
        assert_eq!(wizard.state.disks[0].path, "/d");

        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.disk_field, DiskField::Size);
        wizard.handle(WizardCommand::Increase);
        assert_eq!(wizard.state.disks[0].size_gib, 473);
    }

    #[test]
    fn disk_step_selects_discovered_disks_without_selecting_all() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Disks;
        wizard.state.discovered_disks = vec![
            DiskChoice {
                path: "/dev/nvme0n1".to_string(),
                size_gib: 465,
                model: None,
            },
            DiskChoice {
                path: "/dev/nvme1n1".to_string(),
                size_gib: 465,
                model: None,
            },
        ];
        wizard.state.disks = vec![wizard.state.discovered_disks[0].clone()];
        wizard.state.normalize_disk_roles();

        wizard.handle(WizardCommand::SelectDiskNext);
        assert_eq!(wizard.selected_disk, 1);
        wizard.handle(WizardCommand::Toggle);

        assert_eq!(wizard.state.disks.len(), 2);
        assert_eq!(wizard.state.disks[1].path, "/dev/nvme1n1");

        wizard.handle(WizardCommand::SelectDiskPrevious);
        wizard.handle(WizardCommand::Toggle);
        assert_eq!(wizard.status, "ignored install disk /dev/nvme0n1");
        assert_eq!(wizard.state.disks.len(), 1);
        assert_eq!(wizard.state.disks[0].path, "/dev/nvme1n1");
        assert_eq!(
            wizard.state.disk_role_for_path("/dev/nvme1n1"),
            crate::install::state::DiskRole::System
        );
    }

    #[test]
    fn disk_step_can_promote_visible_disk_to_system_role() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Disks;
        wizard.state.discovered_disks = vec![
            DiskChoice {
                path: "/dev/nvme0n1".to_string(),
                size_gib: 465,
                model: None,
            },
            DiskChoice {
                path: "/dev/nvme1n1".to_string(),
                size_gib: 465,
                model: None,
            },
        ];
        wizard.state.disks = vec![wizard.state.discovered_disks[0].clone()];
        wizard.state.normalize_disk_roles();

        wizard.handle(WizardCommand::SelectDiskNext);
        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.disk_field, DiskField::Role);
        wizard.handle(WizardCommand::Toggle);

        assert_eq!(
            wizard.state.disk_role_for_path("/dev/nvme1n1"),
            crate::install::state::DiskRole::System
        );
        assert_eq!(
            wizard.state.disk_role_for_path("/dev/nvme0n1"),
            crate::install::state::DiskRole::PoolMember
        );
    }

    #[test]
    fn disk_step_cycles_selected_disk_pool() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Disks;
        wizard.state.discovered_disks = vec![
            DiskChoice {
                path: "/dev/nvme0n1".to_string(),
                size_gib: 465,
                model: None,
            },
            DiskChoice {
                path: "/dev/nvme1n1".to_string(),
                size_gib: 465,
                model: None,
            },
        ];
        wizard
            .state
            .set_disk_role("/dev/nvme1n1", crate::install::state::DiskRole::PoolMember);
        wizard.state.ensure_volume_group("extra");

        wizard.handle(WizardCommand::SelectDiskNext);
        wizard.handle(WizardCommand::SelectNext);
        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.disk_field, DiskField::Pool);
        wizard.handle(WizardCommand::Toggle);

        assert_eq!(
            wizard.state.disk_volume_group_for_path("/dev/nvme1n1"),
            Some("extra")
        );
        assert_eq!(wizard.status, "/dev/nvme1n1 pool set to extra");
    }

    #[test]
    fn disk_step_creates_renames_and_deletes_pool() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Disks;

        wizard.handle(WizardCommand::SelectNext);
        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.disk_field, DiskField::Pool);
        wizard.handle(WizardCommand::Increase);

        assert_eq!(
            wizard.state.disk_volume_group_for_path("/dev/nvme0n1"),
            Some("pool1")
        );
        assert_eq!(wizard.status, "created pool pool1 for /dev/nvme0n1");

        wizard.handle(WizardCommand::Insert('x'));
        assert_eq!(
            wizard.state.disk_volume_group_for_path("/dev/nvme0n1"),
            Some("pool1x")
        );
        assert_eq!(wizard.status, "pool pool1 renamed to pool1x");

        wizard.handle(WizardCommand::Backspace);
        assert_eq!(
            wizard.state.disk_volume_group_for_path("/dev/nvme0n1"),
            Some("pool1")
        );
        assert_eq!(wizard.status, "pool pool1x renamed to pool1");

        wizard.handle(WizardCommand::Decrease);
        assert_eq!(
            wizard.state.disk_volume_group_for_path("/dev/nvme0n1"),
            Some("pool")
        );
        assert_eq!(
            wizard.status,
            "deleted pool pool1; assignments moved to default"
        );
    }

    #[test]
    fn pools_step_creates_selects_renames_and_deletes_pool() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Pools;

        wizard.handle(WizardCommand::Increase);
        assert_eq!(wizard.selected_pool, 1);
        assert_eq!(wizard.state.volume_groups[1].name, "pool1");
        assert_eq!(wizard.status, "created pool pool1");

        wizard.handle(WizardCommand::Insert('x'));
        assert_eq!(wizard.state.volume_groups[1].name, "pool1x");
        assert_eq!(wizard.status, "pool pool1 renamed to pool1x");

        wizard.handle(WizardCommand::Backspace);
        assert_eq!(wizard.state.volume_groups[1].name, "pool1");
        assert_eq!(wizard.status, "pool pool1x renamed to pool1");

        wizard.handle(WizardCommand::SelectPrevious);
        assert_eq!(wizard.selected_pool, 0);
        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.selected_pool, 1);

        wizard.handle(WizardCommand::Decrease);
        assert_eq!(wizard.selected_pool, 0);
        assert_eq!(wizard.state.volume_groups.len(), 1);
        assert_eq!(
            wizard.status,
            "deleted pool pool1; assignments moved to default"
        );
    }

    #[test]
    fn pools_step_rejects_deleting_default_pool() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Pools;

        wizard.handle(WizardCommand::Decrease);

        assert_eq!(wizard.state.volume_groups.len(), 1);
        assert_eq!(wizard.status, "default volume group cannot be deleted");
    }

    #[test]
    fn volume_step_cycles_selected_volume_pool() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Volumes;
        wizard.state.ensure_volume_group("extra");

        wizard.handle(WizardCommand::Toggle);
        assert_eq!(wizard.volume_field, VolumeField::Mountpoint);
        wizard.handle(WizardCommand::Toggle);
        assert_eq!(wizard.volume_field, VolumeField::Pool);
        wizard.handle(WizardCommand::Toggle);

        assert_eq!(wizard.state.volume_group_for_volume("root"), "extra");
        assert_eq!(wizard.status, "root pool set to extra");
    }

    #[test]
    fn volume_step_creates_renames_and_deletes_pool() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Volumes;

        wizard.handle(WizardCommand::Toggle);
        wizard.handle(WizardCommand::Toggle);
        assert_eq!(wizard.volume_field, VolumeField::Pool);
        wizard.handle(WizardCommand::Increase);

        assert_eq!(wizard.state.volume_group_for_volume("root"), "pool1");
        assert_eq!(wizard.status, "created pool pool1 for root");

        wizard.handle(WizardCommand::Insert('x'));
        assert_eq!(wizard.state.volume_group_for_volume("root"), "pool1x");
        assert_eq!(wizard.status, "pool pool1 renamed to pool1x");

        wizard.handle(WizardCommand::Backspace);
        assert_eq!(wizard.state.volume_group_for_volume("root"), "pool1");
        assert_eq!(wizard.status, "pool pool1x renamed to pool1");

        wizard.handle(WizardCommand::Decrease);
        assert_eq!(wizard.state.volume_group_for_volume("root"), "pool");
        assert_eq!(
            wizard.status,
            "deleted pool pool1; assignments moved to default"
        );
    }

    #[test]
    fn volume_step_selects_and_edits_volume() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Volumes;
        assert_eq!(wizard.selected_volume, 0);

        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.selected_volume, 1);

        wizard.handle(WizardCommand::Toggle);
        assert_eq!(wizard.volume_field, VolumeField::Mountpoint);
        wizard.handle(WizardCommand::Increase);
        assert_eq!(wizard.state.volumes[1].size_gib, 40);
    }

    #[test]
    fn confirm_must_be_armed_before_install() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Confirm;

        assert_eq!(wizard.handle(WizardCommand::Next), WizardOutcome::Continue);
        assert_eq!(wizard.state.current_step, InstallStep::Confirm);
    }

    #[test]
    fn confirm_can_arm_after_preflight_passes() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Confirm;
        wizard.set_preflight(PreflightReport { checks: vec![] });

        let phrase = wizard.confirmation().phrase;
        for ch in phrase.chars() {
            wizard.handle(WizardCommand::Insert(ch));
        }
        assert_eq!(
            wizard.handle(WizardCommand::Next),
            WizardOutcome::ReadyToInstall
        );
    }

    #[test]
    fn confirm_rejects_wrong_phrase() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Confirm;
        wizard.set_preflight(PreflightReport { checks: vec![] });

        for ch in "WIPE wrong".chars() {
            wizard.handle(WizardCommand::Insert(ch));
        }

        assert!(!wizard.confirm_armed);
        assert_eq!(wizard.handle(WizardCommand::Next), WizardOutcome::Continue);
        assert_eq!(wizard.state.current_step, InstallStep::Confirm);
    }

    #[test]
    fn confirm_backspace_updates_armed_state() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.state.current_step = InstallStep::Confirm;
        wizard.set_preflight(PreflightReport { checks: vec![] });

        let phrase = wizard.confirmation().phrase;
        for ch in phrase.chars() {
            wizard.handle(WizardCommand::Insert(ch));
        }
        assert!(wizard.confirm_armed);

        wizard.handle(WizardCommand::Backspace);

        assert!(!wizard.confirm_armed);
    }
}
