//! Native local install execution.
//!
//! The install plan produced by [`crate::install::plan`] is backend-agnostic: each
//! step is a program plus arguments, where `nox-agent <subcommand>` marks a
//! typed operation. The remote installer interprets those steps over the SSH
//! agent; this module interprets the same steps in-process, calling the agent
//! operation functions directly, so a local install runs the identical plan
//! without SSH.
//!
//! Destructive steps flow through the same [`RemoteExecutionPolicy`] gate as the
//! remote path, so nothing runs unless the caller confirms.

use std::process::Command;

use crate::agent;
use crate::install::executor::{
    execute_remote_plan_with_runner, RemoteExecutionPolicy, RemoteInstallExecution,
    RemoteInstallStepOutput,
};
use crate::install::plan::RemoteInstallStep;
use crate::Result;

/// The typed operations a local install performs. Extracting them behind a trait
/// lets the orchestration be unit-tested with a recording fake instead of running
/// real disk and filesystem mutations.
pub(crate) trait LocalOps {
    fn network_route_cleanup(&mut self) -> Result<StepOutcome>;
    fn storage_overwrite(&mut self, vg_name: &str) -> Result<StepOutcome>;
    fn prepare_disk(&mut self, disk: &str) -> Result<StepOutcome>;
    fn disko_apply(&mut self, disko_file: &str) -> Result<StepOutcome>;
    fn write_secret_key(&mut self, path: &str, mode: u32, bytes: &[u8]) -> Result<StepOutcome>;
    fn config_copy(&mut self, source_dir: &str, role: &str, install_user: &str)
        -> Result<StepOutcome>;
    fn bin_ensure(&mut self, github_token: &[u8]) -> Result<StepOutcome>;
    fn dotfiles_run(
        &mut self,
        dotfiles_repo: &str,
        install_user: &str,
        github_token: &[u8],
    ) -> Result<StepOutcome>;
    fn schedule_reboot(&mut self, delay_secs: u64) -> Result<StepOutcome>;
    fn run_program(&mut self, program: &str, args: &[String], stdin: &[u8]) -> Result<StepOutcome>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StepOutcome {
    pub status: u32,
    pub stdout: String,
    pub stderr: String,
}

impl StepOutcome {
    fn ok(stdout: impl Into<String>) -> Self {
        Self {
            status: 0,
            stdout: stdout.into(),
            stderr: String::new(),
        }
    }
}

pub(crate) fn execute_local_plan(
    ops: &mut dyn LocalOps,
    steps: &[RemoteInstallStep],
    policy: RemoteExecutionPolicy,
) -> Result<RemoteInstallExecution> {
    execute_remote_plan_with_runner(steps, policy, |step| execute_local_step(ops, step))
}

fn execute_local_step(
    ops: &mut dyn LocalOps,
    step: &RemoteInstallStep,
) -> Result<RemoteInstallStepOutput> {
    let outcome = dispatch(ops, step)?;
    Ok(RemoteInstallStepOutput {
        name: step.name.to_string(),
        command: step.command_line(),
        status: outcome.status,
        stdout: outcome.stdout,
        stderr: outcome.stderr,
    })
}

fn dispatch(ops: &mut dyn LocalOps, step: &RemoteInstallStep) -> Result<StepOutcome> {
    if step.program != "nox-agent" {
        return ops.run_program(&step.program, &step.args, &step.stdin);
    }

    let subcommand = step
        .args
        .first()
        .map(String::as_str)
        .ok_or_else(|| format!("local step '{}' has no agent subcommand", step.name))?;

    match subcommand {
        "network-route-cleanup" => ops.network_route_cleanup(),
        "storage-overwrite" => {
            let vg = arg(step, 1, "VG name")?;
            ops.storage_overwrite(vg)
        }
        "disk-prepare" => {
            let disk = arg(step, 1, "disk path")?;
            ops.prepare_disk(disk)
        }
        "disko-apply" => {
            let file = arg(step, 1, "Disko file")?;
            ops.disko_apply(file)
        }
        "secret-file-write" => {
            let path = arg(step, 1, "path")?;
            let mode = arg(step, 2, "mode")?;
            let mode = u32::from_str_radix(mode, 8)
                .map_err(|err| format!("invalid secret write mode {mode}: {err}"))?;
            ops.write_secret_key(path, mode, &step.stdin)
        }
        "config-copy" => {
            let source_dir = arg(step, 1, "source dir")?;
            let role = arg(step, 2, "role")?;
            let install_user = arg(step, 3, "install user")?;
            ops.config_copy(source_dir, role, install_user)
        }
        "system-bin-ensure" => ops.bin_ensure(&step.stdin),
        "dotfiles-run" => {
            let repo = arg(step, 1, "dotfiles repo")?;
            let install_user = arg(step, 2, "install user")?;
            ops.dotfiles_run(repo, install_user, &step.stdin)
        }
        "reboot-target" => ops.schedule_reboot(3),
        other => Err(format!("unknown local agent subcommand: {other}")),
    }
}

fn arg<'a>(step: &'a RemoteInstallStep, index: usize, label: &str) -> Result<&'a str> {
    step.args
        .get(index)
        .map(String::as_str)
        .ok_or_else(|| format!("local step '{}' is missing {label}", step.name))
}

/// Live implementation that performs the real local mutations by calling the
/// agent operation functions in-process and shelling out for plain programs.
pub(crate) struct LiveLocalOps;

impl LocalOps for LiveLocalOps {
    fn network_route_cleanup(&mut self) -> Result<StepOutcome> {
        agent::network_route_cleanup().map(command_result_outcome)
    }

    fn storage_overwrite(&mut self, vg_name: &str) -> Result<StepOutcome> {
        agent::storage_overwrite(vg_name).map(command_result_outcome)
    }

    fn prepare_disk(&mut self, disk: &str) -> Result<StepOutcome> {
        let result = crate::install::disk::local_prepare(disk)?;
        Ok(StepOutcome {
            status: result.status,
            stdout: result.stdout,
            stderr: result.stderr,
        })
    }

    fn disko_apply(&mut self, disko_file: &str) -> Result<StepOutcome> {
        agent::disko_apply(disko_file).map(command_result_outcome)
    }

    fn write_secret_key(&mut self, path: &str, mode: u32, bytes: &[u8]) -> Result<StepOutcome> {
        let result = agent::sudo_write_file(path, bytes, mode, true)?;
        Ok(StepOutcome::ok(format!(
            "wrote {} bytes to {}",
            result.bytes_written, result.path
        )))
    }

    fn config_copy(
        &mut self,
        source_dir: &str,
        role: &str,
        install_user: &str,
    ) -> Result<StepOutcome> {
        agent::config_copy(source_dir, role, install_user).map(command_result_outcome)
    }

    fn bin_ensure(&mut self, github_token: &[u8]) -> Result<StepOutcome> {
        let token = String::from_utf8(github_token.to_vec())
            .map_err(|err| format!("GitHub token is not valid UTF-8: {err}"))?;
        let mut args = Vec::new();
        if !token.is_empty() {
            args.push(format!("GITHUB_TOKEN={token}"));
            args.push(format!("GITHUB_AUTH_TOKEN={token}"));
        }
        args.extend(
            [
                "chroot",
                "/mnt",
                "/nix/var/nix/profiles/system/sw/bin/env",
                "PATH=/nix/var/nix/profiles/system/sw/bin:/usr/local/bin:/bin:/usr/bin",
                "HOME=/root",
                "USER=root",
                "LOGNAME=root",
                "/nix/var/nix/profiles/system/sw/bin/bin",
                "ensure",
            ]
            .into_iter()
            .map(str::to_string),
        );
        let mut sudo_args = vec!["--non-interactive".to_string()];
        if !token.is_empty() {
            sudo_args.push("--preserve-env=GITHUB_TOKEN,GITHUB_AUTH_TOKEN".to_string());
        }
        sudo_args.extend(args);
        run_local_program("sudo", &sudo_args, &[])
    }

    fn dotfiles_run(
        &mut self,
        dotfiles_repo: &str,
        install_user: &str,
        github_token: &[u8],
    ) -> Result<StepOutcome> {
        let mut stdout = std::io::stdout();
        agent::dotfiles_run_streaming(&mut stdout, dotfiles_repo, install_user, github_token)?;
        Ok(StepOutcome::ok("dotfiles run complete"))
    }

    fn schedule_reboot(&mut self, delay_secs: u64) -> Result<StepOutcome> {
        agent::schedule_reboot(delay_secs)?;
        Ok(StepOutcome::ok(format!("reboot scheduled in {delay_secs}s")))
    }

    fn run_program(&mut self, program: &str, args: &[String], stdin: &[u8]) -> Result<StepOutcome> {
        if program == "nixos-install" {
            let mut full = vec![
                "TMPDIR=/tmp".to_string(),
                "sudo".to_string(),
                "--non-interactive".to_string(),
                "nixos-install".to_string(),
            ];
            full.extend(args.iter().cloned());
            return run_local_program("env", &full, stdin);
        }
        run_local_program(program, args, stdin)
    }
}

fn run_local_program(program: &str, args: &[String], stdin: &[u8]) -> Result<StepOutcome> {
    use std::io::Write;
    use std::process::Stdio;

    let mut child = Command::new(program)
        .args(args)
        .stdin(if stdin.is_empty() {
            Stdio::null()
        } else {
            Stdio::piped()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| format!("failed to run {program}: {err}"))?;

    if !stdin.is_empty() {
        child
            .stdin
            .take()
            .ok_or_else(|| "failed to open stdin for local program".to_string())?
            .write_all(stdin)
            .map_err(|err| format!("failed to write stdin to {program}: {err}"))?;
    }

    let output = child
        .wait_with_output()
        .map_err(|err| format!("failed to wait for {program}: {err}"))?;
    Ok(StepOutcome {
        status: output.status.code().unwrap_or(1) as u32,
        stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
    })
}

fn command_result_outcome(result: agent::CommandResult) -> StepOutcome {
    StepOutcome {
        status: result.status,
        stdout: String::from_utf8_lossy(&result.stdout).trim().to_string(),
        stderr: String::from_utf8_lossy(&result.stderr).trim().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::{execute_local_plan, LocalOps, StepOutcome};
    use crate::install::executor::RemoteExecutionPolicy;
    use crate::install::plan::{plan_remote_install_steps_with_secrets, RemoteInstallSecrets};
    use crate::install::state::InstallState;

    #[derive(Default)]
    struct FakeLocalOps {
        calls: Vec<String>,
    }

    impl FakeLocalOps {
        fn record(&mut self, call: impl Into<String>) -> Result<StepOutcome, String> {
            let call = call.into();
            self.calls.push(call.clone());
            Ok(StepOutcome::ok(call))
        }
    }

    impl LocalOps for FakeLocalOps {
        fn network_route_cleanup(&mut self) -> Result<StepOutcome, String> {
            self.record("network-route-cleanup")
        }
        fn storage_overwrite(&mut self, vg: &str) -> Result<StepOutcome, String> {
            self.record(format!("storage-overwrite {vg}"))
        }
        fn prepare_disk(&mut self, disk: &str) -> Result<StepOutcome, String> {
            self.record(format!("disk-prepare {disk}"))
        }
        fn disko_apply(&mut self, file: &str) -> Result<StepOutcome, String> {
            self.record(format!("disko-apply {file}"))
        }
        fn write_secret_key(
            &mut self,
            path: &str,
            mode: u32,
            bytes: &[u8],
        ) -> Result<StepOutcome, String> {
            self.record(format!("secret-write {path} {mode:o} {}", bytes.len()))
        }
        fn config_copy(
            &mut self,
            source_dir: &str,
            role: &str,
            install_user: &str,
        ) -> Result<StepOutcome, String> {
            self.record(format!("config-copy {source_dir} {role} {install_user}"))
        }
        fn bin_ensure(&mut self, token: &[u8]) -> Result<StepOutcome, String> {
            self.record(format!("bin-ensure token={}", token.len()))
        }
        fn dotfiles_run(
            &mut self,
            repo: &str,
            user: &str,
            token: &[u8],
        ) -> Result<StepOutcome, String> {
            self.record(format!("dotfiles-run {repo} {user} token={}", token.len()))
        }
        fn schedule_reboot(&mut self, delay: u64) -> Result<StepOutcome, String> {
            self.record(format!("reboot {delay}"))
        }
        fn run_program(
            &mut self,
            program: &str,
            args: &[String],
            _stdin: &[u8],
        ) -> Result<StepOutcome, String> {
            self.record(format!("program {program} {}", args.join(" ")))
        }
    }

    fn sample_steps() -> Vec<crate::install::plan::RemoteInstallStep> {
        plan_remote_install_steps_with_secrets(
            &InstallState::sample(),
            "/tmp/nx-source",
            RemoteInstallSecrets {
                shared_system_key: Some(b"AGE-SECRET-KEY"),
                github_token: Some(b"ghp_test"),
            },
        )
        .unwrap()
    }

    #[test]
    fn dispatches_every_agent_operation_in_process() {
        let steps = sample_steps();
        let mut ops = FakeLocalOps::default();

        let execution = execute_local_plan(
            &mut ops,
            &steps,
            RemoteExecutionPolicy::allow_destructive_steps(usize::MAX),
        )
        .unwrap();

        assert_eq!(execution.completed.len(), steps.len());
        assert!(execution.refused.is_empty());
        // Typed agent operations are routed to the in-process backend, not shelled out.
        assert!(ops.calls.iter().any(|c| c == "network-route-cleanup"));
        assert!(ops.calls.iter().any(|c| c == "disk-prepare /dev/nvme0n1"));
        assert!(ops
            .calls
            .iter()
            .any(|c| c == "disko-apply /tmp/nx-source/host/generated/disko.nix"));
        assert!(ops
            .calls
            .iter()
            .any(|c| c == "secret-write /mnt/var/lib/sops-nix/key.txt 600 14"));
        assert!(ops
            .calls
            .iter()
            .any(|c| c == "config-copy /tmp/nx-source laptop bresilla"));
        assert!(ops.calls.iter().any(|c| c == "bin-ensure token=8"));
        assert!(ops.calls.iter().any(|c| c.starts_with("dotfiles-run")));
        assert!(ops.calls.iter().any(|c| c == "reboot 3"));
        // Plain programs (id, test, findmnt, nixos-install) go through run_program.
        assert!(ops.calls.iter().any(|c| c.starts_with("program id")));
        assert!(ops.calls.iter().any(|c| c.starts_with("program nixos-install")));
    }

    #[test]
    fn safe_policy_refuses_destructive_steps_locally() {
        let steps = sample_steps();
        let mut ops = FakeLocalOps::default();

        let execution =
            execute_local_plan(&mut ops, &steps, RemoteExecutionPolicy::safe()).unwrap();

        assert!(!execution.refused.is_empty());
        // No destructive typed op runs under the safe policy.
        assert!(!ops.calls.iter().any(|c| c.starts_with("disk-prepare")));
        assert!(!ops.calls.iter().any(|c| c.starts_with("disko-apply")));
    }
}
