use crate::install_state::InstallState;
use crate::{install_disko, Result};

#[derive(Debug, Clone, Copy, Default)]
pub struct RemoteInstallSecrets<'a> {
    pub shared_system_key: Option<&'a [u8]>,
    pub github_token: Option<&'a [u8]>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteInstallStep {
    pub name: &'static str,
    pub program: String,
    pub args: Vec<String>,
    pub stdin: Vec<u8>,
    pub destructive: bool,
}

impl RemoteInstallStep {
    fn new(
        name: &'static str,
        program: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
        destructive: bool,
    ) -> Self {
        Self {
            name,
            program: program.into(),
            args: args.into_iter().map(Into::into).collect(),
            stdin: Vec::new(),
            destructive,
        }
    }

    fn new_with_stdin(
        name: &'static str,
        program: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
        stdin: Vec<u8>,
        destructive: bool,
    ) -> Self {
        Self {
            name,
            program: program.into(),
            args: args.into_iter().map(Into::into).collect(),
            stdin,
            destructive,
        }
    }

    pub fn command_line(&self) -> String {
        std::iter::once(self.program.as_str())
            .chain(self.args.iter().map(String::as_str))
            .map(shell_display)
            .collect::<Vec<_>>()
            .join(" ")
    }
}

struct RemotePaths {
    source_dir: String,
    role: &'static str,
    flake_file: String,
    disko_file: String,
    flake_ref: String,
}

fn remote_paths(state: &InstallState, source_dir: &str) -> Result<RemotePaths> {
    if source_dir.is_empty() || !source_dir.starts_with('/') {
        return Err(format!(
            "remote source directory must be absolute: {source_dir}"
        ));
    }

    let role = state.role.title();
    let flake_host = format!("install-{role}-generated");
    let source_dir = source_dir.trim_end_matches('/');
    if source_dir.is_empty() {
        return Err("remote source directory cannot be filesystem root".to_string());
    }

    Ok(RemotePaths {
        source_dir: source_dir.to_string(),
        role,
        flake_file: format!("{source_dir}/host/flake.nix"),
        disko_file: format!("{source_dir}/host/generated/disko.nix"),
        flake_ref: format!("{source_dir}/host#{flake_host}"),
    })
}

pub fn plan_remote_install_steps(
    state: &InstallState,
    source_dir: &str,
) -> Result<Vec<RemoteInstallStep>> {
    plan_remote_install_steps_with_secrets(state, source_dir, RemoteInstallSecrets::default())
}

/// Plan the storage-only prefix of a remote install: verify the target, clean up
/// competing routes, verify the transferred flake and disko files, remove any
/// existing volume groups in overwrite mode, wipe the selected disks, apply the
/// Disko layout, and confirm the resulting mount. This is the reusable core that
/// both the full installer and the standalone `storage apply` path build on.
pub fn plan_remote_storage_steps(
    state: &InstallState,
    source_dir: &str,
) -> Result<Vec<RemoteInstallStep>> {
    let paths = remote_paths(state, source_dir)?;

    let mut steps = vec![RemoteInstallStep::new(
        "verify remote user",
        "id",
        ["-un"],
        false,
    )];

    if state.network_route_cleanup {
        steps.push(RemoteInstallStep::new(
            "clean up competing default routes",
            "nox-agent",
            ["network-route-cleanup"],
            false,
        ));
    }

    steps.extend([
        RemoteInstallStep::new(
            "verify flake source",
            "test",
            ["-f", paths.flake_file.as_str()],
            false,
        ),
        RemoteInstallStep::new(
            "verify generated disko",
            "test",
            ["-f", paths.disko_file.as_str()],
            false,
        ),
    ]);

    if state.overwrite_existing_storage {
        let vg_names = install_disko::lvm_vg_names(state)?;
        for vg_name in vg_names {
            steps.push(RemoteInstallStep::new(
                "remove existing volume group",
                "nox-agent",
                ["storage-overwrite", vg_name.as_str()],
                true,
            ));
        }
    }

    for disk in &state.disks {
        steps.push(RemoteInstallStep::new(
            "prepare target disk",
            "nox-agent",
            ["disk-prepare", disk.path.as_str()],
            true,
        ));
    }

    steps.extend([
        RemoteInstallStep::new(
            "apply disko layout",
            "nox-agent",
            ["disko-apply", paths.disko_file.as_str()],
            true,
        ),
        RemoteInstallStep::new("verify mounted system", "findmnt", ["/mnt"], false),
    ]);

    Ok(steps)
}

pub fn plan_remote_install_steps_with_secrets(
    state: &InstallState,
    source_dir: &str,
    secrets: RemoteInstallSecrets<'_>,
) -> Result<Vec<RemoteInstallStep>> {
    let paths = remote_paths(state, source_dir)?;
    let source_dir = paths.source_dir.as_str();
    let role = paths.role;
    let flake_ref = paths.flake_ref.as_str();

    let mut steps = plan_remote_storage_steps(state, source_dir)?;

    if let Some(shared_system_key) = secrets.shared_system_key {
        steps.push(RemoteInstallStep::new_with_stdin(
            "copy shared system key",
            "nox-agent",
            ["secret-file-write", "/mnt/var/lib/sops-nix/key.txt", "0600"],
            shared_system_key.to_vec(),
            true,
        ));
    }

    if let Some(password_hash) = &state.user_password_hash {
        // Placed before nixos-install so account activation can read it.
        steps.push(RemoteInstallStep::new_with_stdin(
            "write user password hash",
            "nox-agent",
            [
                "secret-file-write",
                "/mnt/var/lib/nixos-install/user-password.hash",
                "0600",
            ],
            password_hash.as_bytes().to_vec(),
            true,
        ));
    }

    steps.extend([
        RemoteInstallStep::new(
            "install nixos",
            "nixos-install",
            ["--flake", flake_ref, "--no-root-passwd"],
            true,
        ),
        RemoteInstallStep::new(
            "copy system config",
            "nox-agent",
            ["config-copy", source_dir, role, state.install_user.as_str()],
            true,
        ),
    ]);

    if !state.skip_bin_ensure {
        steps.push(RemoteInstallStep::new_with_stdin(
            "run system bin ensure",
            "nox-agent",
            ["system-bin-ensure"],
            secrets.github_token.unwrap_or_default().to_vec(),
            true,
        ));
    }

    if let Some(dotfiles_repo) = normalized_dotfiles_repo(state.dotfiles_repo.as_deref()) {
        steps.push(RemoteInstallStep::new_with_stdin(
            "run dotfiles",
            "nox-agent",
            ["dotfiles-run", dotfiles_repo, state.install_user.as_str()],
            secrets.github_token.unwrap_or_default().to_vec(),
            true,
        ));
    }

    steps.push(RemoteInstallStep::new(
        "reboot target",
        "nox-agent",
        ["reboot-target"],
        true,
    ));

    Ok(steps)
}

#[allow(dead_code)]
pub fn assert_destructive_allowed(step: &RemoteInstallStep, allowed: bool) -> Result<()> {
    if step.destructive && !allowed {
        Err(format!(
            "refusing destructive remote step without confirmation: {}",
            step.name
        ))
    } else {
        Ok(())
    }
}

fn shell_display(value: &str) -> String {
    if value.bytes().all(|byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'-' | b'_' | b'#' | b':')
    }) {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}

fn normalized_dotfiles_repo(value: Option<&str>) -> Option<&str> {
    match value.map(str::trim) {
        None | Some("") | Some("skip") | Some("none") | Some("no") => None,
        Some(value) => Some(value),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        assert_destructive_allowed, plan_remote_install_steps,
        plan_remote_install_steps_with_secrets, RemoteInstallSecrets,
    };
    use crate::install_state::InstallState;

    #[test]
    fn remote_plan_contains_expected_order() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        let names = steps.iter().map(|step| step.name).collect::<Vec<_>>();

        assert_eq!(
            names,
            vec![
                "verify remote user",
                "clean up competing default routes",
                "verify flake source",
                "verify generated disko",
                "prepare target disk",
                "apply disko layout",
                "verify mounted system",
                "install nixos",
                "copy system config",
                "run system bin ensure",
                "run dotfiles",
                "reboot target",
            ]
        );
    }

    #[test]
    fn storage_steps_are_the_install_prefix_through_mount() {
        let state = InstallState::sample();
        let storage = super::plan_remote_storage_steps(&state, "/tmp/nx-source").unwrap();
        let names = storage.iter().map(|step| step.name).collect::<Vec<_>>();

        assert_eq!(
            names,
            vec![
                "verify remote user",
                "clean up competing default routes",
                "verify flake source",
                "verify generated disko",
                "prepare target disk",
                "apply disko layout",
                "verify mounted system",
            ]
        );

        // The storage steps must be a byte-for-byte prefix of the full install plan
        // so the standalone `storage apply` path executes exactly what the installer
        // would for the same state.
        let full = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        assert_eq!(&full[..storage.len()], storage.as_slice());
    }

    #[test]
    fn storage_steps_include_overwrite_removal() {
        let mut state = InstallState::sample();
        state.overwrite_existing_storage = true;
        let storage = super::plan_remote_storage_steps(&state, "/tmp/nx-source").unwrap();
        let overwrite = storage
            .iter()
            .find(|step| step.name == "remove existing volume group")
            .unwrap();

        assert!(overwrite.destructive);
        assert_eq!(overwrite.command_line(), "nox-agent storage-overwrite pool");
        assert!(!storage.iter().any(|step| step.name == "install nixos"));
    }

    #[test]
    fn route_cleanup_can_be_disabled() {
        let mut state = InstallState::sample();
        state.network_route_cleanup = false;
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        let names = steps.iter().map(|step| step.name).collect::<Vec<_>>();

        assert_eq!(
            names[..3],
            [
                "verify remote user",
                "verify flake source",
                "verify generated disko",
            ]
        );
        assert!(!names.contains(&"clean up competing default routes"));
    }

    #[test]
    fn overwrite_mode_removes_existing_vg_before_disk_prepare() {
        let mut state = InstallState::sample();
        state.overwrite_existing_storage = true;
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        let names = steps.iter().map(|step| step.name).collect::<Vec<_>>();

        assert_eq!(
            names[..6],
            [
                "verify remote user",
                "clean up competing default routes",
                "verify flake source",
                "verify generated disko",
                "remove existing volume group",
                "prepare target disk",
            ]
        );

        let overwrite = steps
            .iter()
            .find(|step| step.name == "remove existing volume group")
            .unwrap();
        assert!(overwrite.destructive);
        assert_eq!(
            overwrite.command_line(),
            "nox-agent storage-overwrite pool"
        );
    }

    #[test]
    fn destructive_steps_are_marked() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();

        assert!(!steps[0].destructive);
        assert!(!steps[1].destructive);
        assert!(!steps[2].destructive);
        assert!(
            steps
                .iter()
                .find(|step| step.name == "prepare target disk")
                .unwrap()
                .destructive
        );
        assert!(
            steps
                .iter()
                .find(|step| step.name == "apply disko layout")
                .unwrap()
                .destructive
        );
        assert!(
            steps
                .iter()
                .find(|step| step.name == "install nixos")
                .unwrap()
                .destructive
        );
        assert!(
            steps
                .iter()
                .find(|step| step.name == "reboot target")
                .unwrap()
                .destructive
        );
    }

    #[test]
    fn destructive_steps_require_confirmation() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        let disko = steps
            .iter()
            .find(|step| step.name == "prepare target disk")
            .unwrap();

        assert!(assert_destructive_allowed(disko, false).is_err());
        assert!(assert_destructive_allowed(disko, true).is_ok());
    }

    #[test]
    fn disk_prepare_steps_include_selected_disk_paths() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        let disk_step = steps
            .iter()
            .find(|step| step.name == "prepare target disk")
            .unwrap();

        assert_eq!(disk_step.args, vec!["disk-prepare", "/dev/nvme0n1"]);
    }

    #[test]
    fn shared_key_step_sits_after_mount_before_nixos_install() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps_with_secrets(
            &state,
            "/tmp/nx-source",
            RemoteInstallSecrets {
                shared_system_key: Some(b"AGE-SECRET-KEY"),
                github_token: None,
            },
        )
        .unwrap();
        let names = steps.iter().map(|step| step.name).collect::<Vec<_>>();

        let mount_index = names
            .iter()
            .position(|name| *name == "verify mounted system")
            .unwrap();
        let key_index = names
            .iter()
            .position(|name| *name == "copy shared system key")
            .unwrap();
        let install_index = names
            .iter()
            .position(|name| *name == "install nixos")
            .unwrap();

        assert!(mount_index < key_index);
        assert!(key_index < install_index);
        let key_step = &steps[key_index];
        assert!(key_step.destructive);
        assert_eq!(
            key_step.args,
            vec!["secret-file-write", "/mnt/var/lib/sops-nix/key.txt", "0600"]
        );
        assert_eq!(key_step.stdin, b"AGE-SECRET-KEY");
    }

    #[test]
    fn finish_steps_are_typed_and_keep_github_token_on_stdin() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps_with_secrets(
            &state,
            "/tmp/nx-source",
            RemoteInstallSecrets {
                shared_system_key: Some(b"AGE-SECRET-KEY"),
                github_token: Some(b"ghp_test"),
            },
        )
        .unwrap();

        let config = steps
            .iter()
            .find(|step| step.name == "copy system config")
            .unwrap();
        assert_eq!(
            config.args,
            vec!["config-copy", "/tmp/nx-source", "laptop", "bresilla"]
        );

        let bin = steps
            .iter()
            .find(|step| step.name == "run system bin ensure")
            .unwrap();
        assert_eq!(bin.args, vec!["system-bin-ensure"]);
        assert_eq!(bin.stdin, b"ghp_test");

        let reboot = steps
            .iter()
            .find(|step| step.name == "reboot target")
            .unwrap();
        assert_eq!(reboot.args, vec!["reboot-target"]);
    }

    #[test]
    fn writes_user_password_hash_before_nixos_install() {
        let mut state = InstallState::sample();
        state.user_password_hash = Some("$y$j9T$hashvalue".to_string());
        let steps = plan_remote_install_steps_with_secrets(
            &state,
            "/tmp/nx-source",
            RemoteInstallSecrets {
                shared_system_key: Some(b"AGE-SECRET-KEY"),
                github_token: Some(b"ghp_test"),
            },
        )
        .unwrap();
        let names = steps.iter().map(|step| step.name).collect::<Vec<_>>();

        let password_index = names
            .iter()
            .position(|name| *name == "write user password hash")
            .unwrap();
        let install_index = names.iter().position(|name| *name == "install nixos").unwrap();
        assert!(password_index < install_index);

        let step = &steps[password_index];
        assert!(step.destructive);
        assert_eq!(
            step.args,
            vec![
                "secret-file-write",
                "/mnt/var/lib/nixos-install/user-password.hash",
                "0600"
            ]
        );
        assert_eq!(step.stdin, b"$y$j9T$hashvalue");
    }

    #[test]
    fn omits_password_step_when_no_password_set() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        assert!(!steps.iter().any(|step| step.name == "write user password hash"));
    }

    #[test]
    fn bin_ensure_step_can_be_skipped() {
        let mut state = InstallState::sample();
        state.skip_bin_ensure = true;
        let steps = plan_remote_install_steps_with_secrets(
            &state,
            "/tmp/nx-source",
            RemoteInstallSecrets {
                shared_system_key: Some(b"AGE-SECRET-KEY"),
                github_token: Some(b"ghp_test"),
            },
        )
        .unwrap();

        assert!(!steps.iter().any(|step| step.name == "run system bin ensure"));
        // config-copy still runs; reboot is still the final step.
        assert!(steps.iter().any(|step| step.name == "copy system config"));
        assert_eq!(steps.last().unwrap().name, "reboot target");
    }

    #[test]
    fn dotfiles_step_is_optional_and_uses_github_token_stdin() {
        let mut state = InstallState::sample();
        state.dotfiles_repo = Some("skip".to_string());
        let steps = plan_remote_install_steps_with_secrets(
            &state,
            "/tmp/nx-source",
            RemoteInstallSecrets {
                shared_system_key: Some(b"AGE-SECRET-KEY"),
                github_token: Some(b"ghp_test"),
            },
        )
        .unwrap();
        assert!(!steps.iter().any(|step| step.name == "run dotfiles"));

        state.dotfiles_repo = Some("https://github.com/bresilla/dot.git".to_string());
        let steps = plan_remote_install_steps_with_secrets(
            &state,
            "/tmp/nx-source",
            RemoteInstallSecrets {
                shared_system_key: Some(b"AGE-SECRET-KEY"),
                github_token: Some(b"ghp_test"),
            },
        )
        .unwrap();
        let dotfiles = steps
            .iter()
            .find(|step| step.name == "run dotfiles")
            .unwrap();
        assert_eq!(
            dotfiles.args,
            vec![
                "dotfiles-run",
                "https://github.com/bresilla/dot.git",
                "bresilla"
            ]
        );
        assert_eq!(dotfiles.stdin, b"ghp_test");
    }

    #[test]
    fn rejects_relative_source_dir() {
        let state = InstallState::sample();
        let err = plan_remote_install_steps(&state, "tmp/nx-source").unwrap_err();

        assert!(err.contains("must be absolute"));
    }
}
