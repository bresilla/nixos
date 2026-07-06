use std::path::Path;

use crate::install_exec;
use crate::install_secrets;
use crate::install_ssh;
use crate::install_state::{validate_mountpoint, InstallScope, InstallState};

#[derive(Debug, Clone)]
pub struct PreflightReport {
    pub checks: Vec<PreflightCheck>,
}

#[derive(Debug, Clone)]
pub struct PreflightCheck {
    pub name: &'static str,
    pub status: PreflightStatus,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreflightStatus {
    Pass,
    Fail,
}

impl PreflightReport {
    pub fn pass(&self) -> bool {
        self.checks
            .iter()
            .all(|check| check.status == PreflightStatus::Pass)
    }

    pub fn failed_count(&self) -> usize {
        self.checks
            .iter()
            .filter(|check| check.status == PreflightStatus::Fail)
            .count()
    }
}

pub fn run(repo: &Path, state: &InstallState) -> PreflightReport {
    run_with_checkers(
        repo,
        state,
        install_secrets::check,
        install_ssh::run_command,
    )
}

fn run_with_checkers(
    repo: &Path,
    state: &InstallState,
    secret_checker: fn(&Path) -> install_secrets::SecretCheck,
    remote_runner: fn(&str, &str) -> Result<install_ssh::RemoteCommandOutput, String>,
) -> PreflightReport {
    let mut checks = Vec::new();
    checks.push(capacity_check(state));
    checks.push(target_check(state));
    if state.scope == InstallScope::Remote {
        checks.push(ssh_check(state));
        checks.push(remote_tools_check(state, remote_runner));
    }
    checks.push(generated_config_check(repo, state));
    checks.push(secrets_check(repo, secret_checker));
    PreflightReport { checks }
}

fn ssh_check(state: &InstallState) -> PreflightCheck {
    let check = install_ssh::check_key_auth(&state.remote);
    if check.ok {
        pass("ssh", check.detail)
    } else {
        fail("ssh", check.detail)
    }
}

fn remote_tools_check(
    state: &InstallState,
    remote_runner: fn(&str, &str) -> Result<install_ssh::RemoteCommandOutput, String>,
) -> PreflightCheck {
    const COMMAND: &str = r#"set -eu
for cmd in bash lsblk sudo; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing command: $cmd" >&2
    exit 10
  }
done
sudo -n true >/dev/null 2>&1 || {
  echo "passwordless sudo failed" >&2
  exit 11
}
printf 'remote user: '
id -un
"#;

    match remote_runner(&state.remote, COMMAND) {
        Ok(output) if output.status == 0 => {
            let detail = String::from_utf8_lossy(&output.stdout).trim().to_string();
            pass(
                "remote tools",
                if detail.is_empty() {
                    "bash, lsblk, sudo, and sudo -n are available".to_string()
                } else {
                    format!("bash, lsblk, sudo, and sudo -n are available ({detail})")
                },
            )
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            fail(
                "remote tools",
                if stderr.is_empty() {
                    format!("remote command exited with {}", output.status)
                } else {
                    format!("remote command exited with {}: {stderr}", output.status)
                },
            )
        }
        Err(err) => fail("remote tools", err),
    }
}

fn capacity_check(state: &InstallState) -> PreflightCheck {
    let total = state.total_disk_gib();
    let used = state.used_gib();
    if total == 0 {
        return fail("capacity", "no install disk selected");
    }
    if used > total {
        return fail(
            "capacity",
            format!("{used}G selected volumes exceed {total}G selected disk capacity"),
        );
    }
    pass(
        "capacity",
        format!("{used}G used / {total}G total / {}G free", total - used),
    )
}

fn target_check(state: &InstallState) -> PreflightCheck {
    if let Err(err) = validate_hostname(&state.hostname) {
        return fail("target", err);
    }
    if let Err(err) = validate_username(&state.install_user) {
        return fail("target", err);
    }
    match state.scope {
        InstallScope::Remote => {
            if state.remote.trim().is_empty() {
                return fail("target", "remote target is required");
            }
            if !state.remote.contains('@') {
                return fail(
                    "target",
                    format!("remote should look like user@host: {}", state.remote),
                );
            }
            pass(
                "target",
                format!("remote {} host {}", state.remote, state.hostname),
            )
        }
        InstallScope::Local => match validate_mountpoint(&state.mountpoint) {
            Ok(()) => pass(
                "target",
                format!(
                    "local mountpoint {} host {}",
                    state.mountpoint, state.hostname
                ),
            ),
            Err(err) => fail("target", err),
        },
    }
}

fn generated_config_check(repo: &Path, state: &InstallState) -> PreflightCheck {
    match install_exec::prepare_generated(repo, state) {
        Ok(()) => pass("generated config", "disko.nix, host.nix, user.nix parse"),
        Err(err) => fail("generated config", err),
    }
}

fn secrets_check(
    repo: &Path,
    secret_checker: fn(&Path) -> install_secrets::SecretCheck,
) -> PreflightCheck {
    let check = secret_checker(repo);
    if check.ok {
        pass("secrets", check.detail)
    } else {
        fail("secrets", check.detail)
    }
}

fn pass(name: &'static str, detail: impl Into<String>) -> PreflightCheck {
    PreflightCheck {
        name,
        status: PreflightStatus::Pass,
        detail: detail.into(),
    }
}

fn fail(name: &'static str, detail: impl Into<String>) -> PreflightCheck {
    PreflightCheck {
        name,
        status: PreflightStatus::Fail,
        detail: detail.into(),
    }
}

fn validate_hostname(value: &str) -> Result<(), String> {
    if value.is_empty() || value.len() > 63 {
        return Err(format!("invalid hostname: {value}"));
    }
    let bytes = value.as_bytes();
    if !bytes[0].is_ascii_alphanumeric() || !bytes[bytes.len() - 1].is_ascii_alphanumeric() {
        return Err(format!("invalid hostname: {value}"));
    }
    if bytes
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-')
    {
        Ok(())
    } else {
        Err(format!("invalid hostname: {value}"))
    }
}

fn validate_username(value: &str) -> Result<(), String> {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return Err("username is required".to_string());
    };
    if !(first.is_ascii_lowercase() || first == '_') {
        return Err(format!("invalid username: {value}"));
    }
    if chars.all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_' || ch == '-') {
        Ok(())
    } else {
        Err(format!("invalid username: {value}"))
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{remote_tools_check, run_with_checkers, PreflightStatus};
    use crate::install_secrets::SecretCheck;
    use crate::install_ssh::RemoteCommandOutput;
    use crate::install_state::InstallState;

    #[test]
    fn preflight_passes_for_sample_state() {
        let dir = temp_dir("pass");
        fs::create_dir_all(&dir).unwrap();
        let mut state = InstallState::sample();
        state.scope = crate::install_state::InstallScope::Local;
        let report = run_with_checkers(&dir, &state, fake_secret_ok, fake_remote_ok);

        assert!(report.pass());
        assert_eq!(report.failed_count(), 0);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn preflight_fails_over_capacity() {
        let dir = temp_dir("capacity");
        fs::create_dir_all(&dir).unwrap();
        let mut state = InstallState::sample();
        state.scope = crate::install_state::InstallScope::Local;
        state.disks[0].size_gib = 100;
        let report = run_with_checkers(&dir, &state, fake_secret_ok, fake_remote_ok);

        assert!(!report.pass());
        assert!(report
            .checks
            .iter()
            .any(|check| check.name == "capacity" && check.status == PreflightStatus::Fail));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn preflight_fails_bad_remote() {
        let dir = temp_dir("target");
        fs::create_dir_all(&dir).unwrap();
        let mut state = InstallState::sample();
        state.remote = "10.10.10.7".to_string();
        let report = run_with_checkers(&dir, &state, fake_secret_ok, fake_remote_ok);

        assert!(!report.pass());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn local_preflight_does_not_add_ssh_check() {
        let dir = temp_dir("local");
        fs::create_dir_all(&dir).unwrap();
        let mut state = InstallState::sample();
        state.scope = crate::install_state::InstallScope::Local;
        let report = run_with_checkers(&dir, &state, fake_secret_ok, fake_remote_ok);

        assert!(!report.checks.iter().any(|check| check.name == "ssh"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn preflight_fails_when_secret_check_fails() {
        let dir = temp_dir("secrets");
        fs::create_dir_all(&dir).unwrap();
        let mut state = InstallState::sample();
        state.scope = crate::install_state::InstallScope::Local;
        let report = run_with_checkers(
            &dir,
            &state,
            |_| SecretCheck {
                ok: false,
                detail: "no yubikey".to_string(),
            },
            fake_remote_ok,
        );

        assert!(!report.pass());
        assert!(report
            .checks
            .iter()
            .any(|check| check.name == "secrets" && check.status == PreflightStatus::Fail));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn remote_tools_check_passes_with_required_tools() {
        let state = InstallState::sample();
        let check = remote_tools_check(&state, fake_remote_ok);

        assert_eq!(check.status, PreflightStatus::Pass);
        assert_eq!(check.name, "remote tools");
    }

    #[test]
    fn remote_tools_check_fails_when_remote_command_fails() {
        let state = InstallState::sample();
        let check = remote_tools_check(&state, fake_remote_fail);

        assert_eq!(check.status, PreflightStatus::Fail);
        assert!(check.detail.contains("missing command"));
    }

    fn fake_secret_ok(_: &Path) -> SecretCheck {
        SecretCheck {
            ok: true,
            detail: "ok".to_string(),
        }
    }

    fn fake_remote_ok(_: &str, _: &str) -> Result<RemoteCommandOutput, String> {
        Ok(RemoteCommandOutput {
            status: 0,
            stdout: b"remote user: nixos\n".to_vec(),
            stderr: Vec::new(),
        })
    }

    fn fake_remote_fail(_: &str, _: &str) -> Result<RemoteCommandOutput, String> {
        Ok(RemoteCommandOutput {
            status: 10,
            stdout: Vec::new(),
            stderr: b"missing command: sudo\n".to_vec(),
        })
    }

    fn temp_dir(name: &str) -> PathBuf {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "nx-rs-preflight-{name}-{}-{now}",
            std::process::id()
        ))
    }
}
