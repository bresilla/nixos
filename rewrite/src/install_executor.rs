use crate::install_disk::DiskPrepareResult;
use crate::install_plan::RemoteInstallStep;
use crate::install_remote::{RemoteInstallSession, RemoteStepResult};
use crate::Result;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RemoteExecutionPolicy {
    pub destructive_steps_allowed: usize,
}

impl RemoteExecutionPolicy {
    pub fn safe() -> Self {
        Self {
            destructive_steps_allowed: 0,
        }
    }

    pub fn allow_destructive_steps(destructive_steps_allowed: usize) -> Self {
        Self {
            destructive_steps_allowed,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteInstallExecution {
    pub completed: Vec<RemoteInstallStepOutput>,
    pub refused: Vec<RemoteInstallRefusal>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteInstallStepOutput {
    pub name: String,
    pub command: String,
    pub status: u32,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteInstallRefusal {
    pub name: String,
    pub command: String,
}

pub fn execute_remote_plan(
    session: &mut RemoteInstallSession,
    steps: &[RemoteInstallStep],
    policy: RemoteExecutionPolicy,
) -> Result<RemoteInstallExecution> {
    execute_remote_plan_with_runner(steps, policy, |step| execute_remote_step(session, step))
}

fn execute_remote_step(
    session: &mut RemoteInstallSession,
    step: &RemoteInstallStep,
) -> Result<RemoteInstallStepOutput> {
    if step.program == "nx-rs-agent"
        && step.args.first().map(String::as_str) == Some("disk-prepare")
    {
        let disk = step
            .args
            .get(1)
            .ok_or_else(|| "disk-prepare step is missing disk path".to_string())?;
        return Ok(output_from_disk_prepare(step, session.prepare_disk(disk)?));
    }

    if step.program == "nx-rs-agent"
        && step.args.first().map(String::as_str) == Some("network-route-cleanup")
    {
        return Ok(output_from_remote_step(
            step,
            session.network_route_cleanup()?,
        ));
    }

    if step.program == "nx-rs-agent"
        && step.args.first().map(String::as_str) == Some("storage-overwrite")
    {
        let vg_name = step
            .args
            .get(1)
            .ok_or_else(|| "storage-overwrite step is missing VG name".to_string())?;
        validate_vg_name(vg_name)?;
        return Ok(output_from_remote_step(
            step,
            session.storage_overwrite(vg_name)?,
        ));
    }

    if step.program == "nx-rs-agent"
        && step.args.first().map(String::as_str) == Some("secret-file-write")
    {
        let path = step
            .args
            .get(1)
            .ok_or_else(|| "secret-file-write step is missing path".to_string())?;
        let mode = step
            .args
            .get(2)
            .ok_or_else(|| "secret-file-write step is missing mode".to_string())?;
        validate_secret_write(path, mode, &step.stdin)?;
        let mode = u32::from_str_radix(mode, 8)
            .map_err(|err| format!("invalid secret write mode {mode}: {err}"))?;
        let mut result = session.sudo_write_file(path, &step.stdin, mode, true)?;
        result.name = step.name.to_string();
        return Ok(output_from_remote_step(step, result));
    }

    if step.program == "nx-rs-agent" && step.args.first().map(String::as_str) == Some("disko-apply")
    {
        let disko_file = step
            .args
            .get(1)
            .ok_or_else(|| "disko-apply step is missing Disko file path".to_string())?;
        validate_absolute_path(disko_file, "disko file")?;
        let mut result = session.disko_apply(disko_file)?;
        result.name = step.name.to_string();
        return Ok(output_from_remote_step(step, result));
    }

    if step.program == "nx-rs-agent" && step.args.first().map(String::as_str) == Some("config-copy")
    {
        let source_dir = step
            .args
            .get(1)
            .ok_or_else(|| "config-copy step is missing source dir".to_string())?;
        let role = step
            .args
            .get(2)
            .ok_or_else(|| "config-copy step is missing role".to_string())?;
        let install_user = step
            .args
            .get(3)
            .ok_or_else(|| "config-copy step is missing install user".to_string())?;
        validate_config_copy(source_dir, role, install_user)?;
        let mut result = session.config_copy(source_dir, role, install_user)?;
        result.name = step.name.to_string();
        return Ok(output_from_remote_step(step, result));
    }

    if step.program == "nixos-install" {
        let mut args = vec![
            "TMPDIR=/tmp".to_string(),
            "sudo".to_string(),
            "--non-interactive".to_string(),
            "nixos-install".to_string(),
        ];
        args.extend(step.args.clone());
        return Ok(output_from_remote_step(
            step,
            session.run_checked_step(&step.name, "env", &args, &step.stdin)?,
        ));
    }

    if step.program == "nx-rs-agent"
        && step.args.first().map(String::as_str) == Some("system-bin-ensure")
    {
        let token = String::from_utf8(step.stdin.clone())
            .map_err(|err| format!("GitHub token is not valid UTF-8: {err}"))?;
        let mut env = Vec::new();
        if !token.is_empty() {
            env.push(("GITHUB_TOKEN".to_string(), token.clone()));
            env.push(("GITHUB_AUTH_TOKEN".to_string(), token));
        }

        let args = vec![
            "--non-interactive".to_string(),
            "--preserve-env=GITHUB_TOKEN,GITHUB_AUTH_TOKEN".to_string(),
            "chroot".to_string(),
            "/mnt".to_string(),
            "/nix/var/nix/profiles/system/sw/bin/env".to_string(),
            "PATH=/nix/var/nix/profiles/system/sw/bin:/usr/local/bin:/bin:/usr/bin".to_string(),
            "HOME=/root".to_string(),
            "USER=root".to_string(),
            "LOGNAME=root".to_string(),
            "/nix/var/nix/profiles/system/sw/bin/bin".to_string(),
            "ensure".to_string(),
        ];
        let mut result = session.run_checked_step_env(&step.name, "sudo", &args, &[], &env)?;

        let bin_dir = session.run_step(
            "check system bin dir",
            "test",
            &["-d".to_string(), "/mnt/usr/local/bin".to_string()],
            &[],
        )?;
        if bin_dir.status == 0 {
            let chmod = session.run_checked_step(
                "fix system bin permissions",
                "sudo",
                &[
                    "--non-interactive".to_string(),
                    "find".to_string(),
                    "/mnt/usr/local/bin".to_string(),
                    "-maxdepth".to_string(),
                    "1".to_string(),
                    "-type".to_string(),
                    "f".to_string(),
                    "-exec".to_string(),
                    "chmod".to_string(),
                    "0755".to_string(),
                    "{}".to_string(),
                    "+".to_string(),
                ],
                &[],
            )?;
            append_step_output(&mut result.stdout, &chmod.stdout);
            append_step_output(&mut result.stderr, &chmod.stderr);
        }

        return Ok(output_from_remote_step(step, result));
    }

    if step.program == "nx-rs-agent"
        && step.args.first().map(String::as_str) == Some("dotfiles-run")
    {
        let dotfiles_repo = step
            .args
            .get(1)
            .ok_or_else(|| "dotfiles-run step is missing repo".to_string())?;
        let install_user = step
            .args
            .get(2)
            .ok_or_else(|| "dotfiles-run step is missing install user".to_string())?;
        validate_dotfiles_run(dotfiles_repo, install_user)?;
        let mut result = session.dotfiles_run(dotfiles_repo, install_user, &step.stdin)?;
        result.name = step.name.to_string();
        return Ok(output_from_remote_step(step, result));
    }

    if step.program == "nx-rs-agent"
        && step.args.first().map(String::as_str) == Some("reboot-target")
    {
        let mut result = session.schedule_reboot(3)?;
        result.name = step.name.to_string();
        return Ok(output_from_remote_step(step, result));
    }

    if step.program == "disko-mount-script" {
        return Err(
            "remote mount-script execution is not wired yet; refusing virtual planner step"
                .to_string(),
        );
    }

    Ok(output_from_remote_step(
        step,
        session.run_checked_step(&step.name, &step.program, &step.args, &step.stdin)?,
    ))
}

pub(crate) fn execute_remote_plan_with_runner(
    steps: &[RemoteInstallStep],
    policy: RemoteExecutionPolicy,
    mut runner: impl FnMut(&RemoteInstallStep) -> Result<RemoteInstallStepOutput>,
) -> Result<RemoteInstallExecution> {
    let mut completed = Vec::new();
    let mut destructive_steps_run = 0;

    for (index, step) in steps.iter().enumerate() {
        if step.destructive && destructive_steps_run >= policy.destructive_steps_allowed {
            let refused = steps[index..]
                .iter()
                .filter(|step| step.destructive)
                .map(refusal_from_step)
                .collect();
            return Ok(RemoteInstallExecution { completed, refused });
        }

        println!("running: {} :: {}", step.name, step.command_line());
        let output = runner(step)?;
        println!(
            "completed: {} status={} :: {}",
            output.name, output.status, output.command
        );
        if !output.stdout.is_empty() {
            println!("  stdout: {}", output.stdout);
        }
        if !output.stderr.is_empty() {
            println!("  stderr: {}", output.stderr);
        }
        if output.status != 0 {
            return Err(remote_step_failure(&output));
        }
        completed.push(output);
        if step.destructive {
            destructive_steps_run += 1;
        }
    }

    Ok(RemoteInstallExecution {
        completed,
        refused: Vec::new(),
    })
}

fn remote_step_failure(output: &RemoteInstallStepOutput) -> String {
    let detail = if !output.stderr.is_empty() {
        output.stderr.as_str()
    } else if !output.stdout.is_empty() {
        output.stdout.as_str()
    } else {
        ""
    };
    if detail.is_empty() {
        format!(
            "remote step '{}' exited with {}",
            output.name, output.status
        )
    } else {
        format!(
            "remote step '{}' exited with {}: {}",
            output.name, output.status, detail
        )
    }
}

fn validate_vg_name(name: &str) -> Result<()> {
    if name.is_empty() {
        return Err("VG name is empty".to_string());
    }
    if !name
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'+'))
    {
        return Err(format!("invalid VG name: {name}"));
    }
    Ok(())
}

fn validate_config_copy(source_dir: &str, role: &str, install_user: &str) -> Result<()> {
    if source_dir.is_empty() || !source_dir.starts_with('/') {
        return Err(format!(
            "config-copy source dir must be absolute: {source_dir}"
        ));
    }
    if source_dir == "/" {
        return Err("config-copy source dir cannot be filesystem root".to_string());
    }
    if !matches!(role, "laptop" | "server") {
        return Err(format!("invalid config-copy role: {role}"));
    }
    validate_install_user(install_user)
}

fn validate_absolute_path(path: &str, label: &str) -> Result<()> {
    if path.is_empty() || !path.starts_with('/') || path.contains('\0') {
        return Err(format!("{label} must be an absolute path: {path}"));
    }
    Ok(())
}

fn validate_dotfiles_run(dotfiles_repo: &str, install_user: &str) -> Result<()> {
    if dotfiles_repo.trim().is_empty() {
        return Err("dotfiles repo is empty".to_string());
    }
    if dotfiles_repo.contains('\0')
        || dotfiles_repo.contains(char::is_whitespace)
        || dotfiles_repo.starts_with('-')
    {
        return Err(format!("invalid dotfiles repo: {dotfiles_repo}"));
    }
    validate_install_user(install_user)
}

fn validate_install_user(value: &str) -> Result<()> {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return Err("install user is empty".to_string());
    };
    if !(first.is_ascii_lowercase() || first == '_') {
        return Err(format!("invalid install user: {value}"));
    }
    if chars.all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_' || ch == '-') {
        Ok(())
    } else {
        Err(format!("invalid install user: {value}"))
    }
}

fn validate_secret_write(path: &str, mode: &str, stdin: &[u8]) -> Result<()> {
    if path != "/mnt/var/lib/sops-nix/key.txt" {
        return Err(format!("unsupported secret write path: {path}"));
    }
    if mode != "0600" {
        return Err(format!("unsupported secret write mode: {mode}"));
    }
    if stdin.is_empty() {
        return Err("secret-file-write stdin is empty".to_string());
    }
    Ok(())
}

fn output_from_remote_step(
    step: &RemoteInstallStep,
    result: RemoteStepResult,
) -> RemoteInstallStepOutput {
    RemoteInstallStepOutput {
        name: result.name,
        command: step.command_line(),
        status: result.status,
        stdout: result.stdout,
        stderr: result.stderr,
    }
}

fn append_step_output(target: &mut String, addition: &str) {
    if addition.is_empty() {
        return;
    }
    if !target.is_empty() {
        target.push('\n');
    }
    target.push_str(addition);
}

fn output_from_disk_prepare(
    step: &RemoteInstallStep,
    result: DiskPrepareResult,
) -> RemoteInstallStepOutput {
    RemoteInstallStepOutput {
        name: step.name.to_string(),
        command: step.command_line(),
        status: result.status,
        stdout: result.stdout,
        stderr: result.stderr,
    }
}

fn refusal_from_step(step: &RemoteInstallStep) -> RemoteInstallRefusal {
    RemoteInstallRefusal {
        name: step.name.to_string(),
        command: step.command_line(),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        execute_remote_plan_with_runner, validate_config_copy, validate_dotfiles_run,
        validate_secret_write, RemoteExecutionPolicy, RemoteInstallStepOutput,
    };
    use crate::install_plan::plan_remote_install_steps;
    use crate::install_state::InstallState;

    #[test]
    fn safe_mode_runs_safe_steps_then_refuses_destructive_tail() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        let execution =
            execute_remote_plan_with_runner(&steps, RemoteExecutionPolicy::safe(), |step| {
                Ok(RemoteInstallStepOutput {
                    name: step.name.to_string(),
                    command: step.command_line(),
                    status: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                })
            })
            .unwrap();

        assert_eq!(
            execution
                .completed
                .iter()
                .map(|step| step.name.as_str())
                .collect::<Vec<_>>(),
            vec![
                "verify remote user",
                "clean up competing default routes",
                "verify flake source",
                "verify generated disko",
            ]
        );
        assert_eq!(
            execution
                .refused
                .iter()
                .map(|step| step.name.as_str())
                .collect::<Vec<_>>(),
            vec![
                "prepare target disk",
                "apply disko layout",
                "install nixos",
                "copy system config",
                "run system bin ensure",
                "run dotfiles",
                "reboot target",
            ]
        );
    }

    #[test]
    fn confirmed_mode_runs_destructive_steps() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        let execution = execute_remote_plan_with_runner(
            &steps,
            RemoteExecutionPolicy::allow_destructive_steps(usize::MAX),
            |step| {
                Ok(RemoteInstallStepOutput {
                    name: step.name.to_string(),
                    command: step.command_line(),
                    status: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                })
            },
        )
        .unwrap();

        assert_eq!(execution.completed.len(), steps.len());
        assert!(execution.refused.is_empty());
    }

    #[test]
    fn non_zero_step_status_stops_execution() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        let err = execute_remote_plan_with_runner(
            &steps,
            RemoteExecutionPolicy::allow_destructive_steps(usize::MAX),
            |step| {
                let status = if step.name == "apply disko layout" {
                    1
                } else {
                    0
                };
                Ok(RemoteInstallStepOutput {
                    name: step.name.to_string(),
                    command: step.command_line(),
                    status,
                    stdout: String::new(),
                    stderr: "disko failed".to_string(),
                })
            },
        )
        .unwrap_err();

        assert!(err.contains("apply disko layout"));
        assert!(err.contains("disko failed"));
    }

    #[test]
    fn destructive_limit_stops_after_allowed_count() {
        let state = InstallState::sample();
        let steps = plan_remote_install_steps(&state, "/tmp/nx-source").unwrap();
        let execution = execute_remote_plan_with_runner(
            &steps,
            RemoteExecutionPolicy::allow_destructive_steps(1),
            |step| {
                Ok(RemoteInstallStepOutput {
                    name: step.name.to_string(),
                    command: step.command_line(),
                    status: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                })
            },
        )
        .unwrap();

        assert_eq!(
            execution
                .completed
                .iter()
                .map(|step| step.name.as_str())
                .collect::<Vec<_>>(),
            vec![
                "verify remote user",
                "clean up competing default routes",
                "verify flake source",
                "verify generated disko",
                "prepare target disk",
            ]
        );
        assert_eq!(
            execution
                .refused
                .iter()
                .map(|step| step.name.as_str())
                .collect::<Vec<_>>(),
            vec![
                "apply disko layout",
                "install nixos",
                "copy system config",
                "run system bin ensure",
                "run dotfiles",
                "reboot target",
            ]
        );
    }

    #[test]
    fn secret_write_validation_is_narrow() {
        assert!(validate_secret_write("/mnt/var/lib/sops-nix/key.txt", "0600", b"key").is_ok());
        assert!(validate_secret_write("/mnt/tmp/key.txt", "0600", b"key").is_err());
        assert!(validate_secret_write("/mnt/var/lib/sops-nix/key.txt", "0644", b"key").is_err());
        assert!(validate_secret_write("/mnt/var/lib/sops-nix/key.txt", "0600", b"").is_err());
    }

    #[test]
    fn config_copy_validation_is_narrow() {
        assert!(validate_config_copy("/tmp/nx-source", "laptop", "bresilla").is_ok());
        assert!(validate_config_copy("tmp/nx-source", "laptop", "bresilla").is_err());
        assert!(validate_config_copy("/", "laptop", "bresilla").is_err());
        assert!(validate_config_copy("/tmp/nx-source", "desktop", "bresilla").is_err());
        assert!(validate_config_copy("/tmp/nx-source", "laptop", "Bad").is_err());
    }

    #[test]
    fn dotfiles_run_validation_is_narrow() {
        assert!(validate_dotfiles_run("https://github.com/bresilla/dot.git", "bresilla").is_ok());
        assert!(validate_dotfiles_run("", "bresilla").is_err());
        assert!(validate_dotfiles_run("-bad", "bresilla").is_err());
        assert!(
            validate_dotfiles_run("https://github.com/bresilla/dot.git --depth 1", "bresilla")
                .is_err()
        );
        assert!(validate_dotfiles_run("https://github.com/bresilla/dot.git", "Bad").is_err());
    }
}
