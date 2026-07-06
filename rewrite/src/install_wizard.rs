use crate::install_confirm::DestructiveConfirmation;
use crate::install_preflight::PreflightReport;
use crate::install_state::{InstallState, InstallStep, Mountpoint, Volume};

#[derive(Debug, Clone)]
pub struct InstallWizard {
    pub state: InstallState,
    pub status: String,
    pub target_field: TargetField,
    pub disk_field: DiskField,
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
    Path,
    Size,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VolumeField {
    Name,
    Mountpoint,
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
            disk_field: DiskField::Path,
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
                if let Some(disk) = self.state.disks.first_mut() {
                    match self.disk_field {
                        DiskField::Path if valid_disk_char(ch) => disk.path.push(ch),
                        DiskField::Size if ch.is_ascii_digit() => {
                            let mut value = disk.size_gib.to_string();
                            value.push(ch);
                            if let Ok(parsed) = value.parse::<u64>() {
                                disk.size_gib = parsed.min(100_000);
                            }
                        }
                        _ => {}
                    }
                }
                self.status = format!("editing disk {}", self.disk_field.title());
            }
            InstallStep::Volumes => {
                let field = self.volume_field;
                if let Some(volume) = self.selected_volume_mut() {
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
                self.state.role = self.state.role.next();
                self.status = format!("role set to {}", self.state.role.title());
            }
            InstallStep::Volumes => {
                self.volume_field = self.volume_field.next();
                self.status = format!("editing volume {}", self.volume_field.title());
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
                if let Some(disk) = self.state.disks.first_mut() {
                    match self.disk_field {
                        DiskField::Path => {
                            disk.path.pop();
                        }
                        DiskField::Size => disk.size_gib /= 10,
                    }
                }
                self.status = format!("editing disk {}", self.disk_field.title());
            }
            InstallStep::Volumes => {
                let field = self.volume_field;
                if let Some(volume) = self.selected_volume_mut() {
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
                if let Some(disk) = self.state.disks.first_mut() {
                    disk.size_gib = apply_delta(disk.size_gib, step);
                    self.status = format!("disk size set to {}G", disk.size_gib);
                }
            }
            InstallStep::Volumes => {
                if let Some(volume) = self.selected_volume_mut() {
                    volume.size_gib = apply_delta(volume.size_gib, step);
                    self.status = format!("{} size set to {}G", volume.name, volume.size_gib);
                }
            }
            _ => {}
        }
    }

    fn selected_volume_mut(&mut self) -> Option<&mut Volume> {
        self.state.volumes.get_mut(self.selected_volume)
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
            DiskField::Path => "path",
            DiskField::Size => "size",
        }
    }

    fn next(self) -> Self {
        match self {
            DiskField::Path => DiskField::Size,
            DiskField::Size => DiskField::Path,
        }
    }

    fn previous(self) -> Self {
        self.next()
    }
}

impl VolumeField {
    pub fn title(self) -> &'static str {
        match self {
            VolumeField::Name => "name",
            VolumeField::Mountpoint => "mountpoint",
            VolumeField::Size => "size",
        }
    }

    fn next(self) -> Self {
        match self {
            VolumeField::Name => VolumeField::Mountpoint,
            VolumeField::Mountpoint => VolumeField::Size,
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
        InstallStep::Role => "left/right changes role",
        InstallStep::Disks => "disk discovery/editing is next",
        InstallStep::Volumes => "volume editing is next",
        InstallStep::Secrets => "left/right toggles draft secret readiness",
        InstallStep::Confirm => "confirm screen will gate destructive actions",
        InstallStep::Install => "install execution is still delegated",
    }
}

#[cfg(test)]
mod tests {
    use super::{DiskField, InstallWizard, TargetField, VolumeField, WizardCommand, WizardOutcome};
    use crate::install_preflight::PreflightReport;
    use crate::install_state::{InstallRole, InstallScope, InstallState, InstallStep};

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
    fn role_step_changes_role() {
        let mut wizard = InstallWizard::new(InstallState::draft());
        wizard.handle(WizardCommand::Next);
        assert_eq!(wizard.state.current_step, InstallStep::Role);
        assert_eq!(wizard.state.role, InstallRole::Laptop);

        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.state.role, InstallRole::Server);

        wizard.handle(WizardCommand::SelectPrevious);
        assert_eq!(wizard.state.role, InstallRole::Laptop);
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

        wizard.handle(WizardCommand::Insert('/'));
        wizard.handle(WizardCommand::Insert('d'));
        assert_eq!(wizard.state.disks[0].path, "/d");

        wizard.handle(WizardCommand::SelectNext);
        assert_eq!(wizard.disk_field, DiskField::Size);
        wizard.handle(WizardCommand::Increase);
        assert_eq!(wizard.state.disks[0].size_gib, 473);
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
