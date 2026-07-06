use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::agent_bootstrap;
use crate::agent_client;
use crate::install_disk::DiskPrepareResult;
use crate::install_disko;
use crate::install_state::{validate_mountpoint, InstallScope, InstallState};
use crate::nix_ast;
use crate::{exec_status, Result};

pub fn prepare_generated(repo: &Path, state: &InstallState) -> Result<()> {
    validate_state(state)?;
    install_disko::write(repo, state)?;
    write_host(repo, state)?;
    write_user(repo, state)?;

    for file in generated_nix_files(repo) {
        let report = nix_ast::parse_file(&file)?;
        if !report.is_ok() {
            return Err(format!(
                "generated file {} has Nix parse errors: {}",
                file.display(),
                report.errors.join("; ")
            ));
        }
    }
    Ok(())
}

#[allow(dead_code)]
pub fn run(repo: &Path, state: &InstallState) -> Result<u8> {
    prepare_generated(repo, state)?;
    run_backend(repo, state, false)
}

pub fn run_confirmed(repo: &Path, state: &InstallState) -> Result<u8> {
    prepare_generated(repo, state)?;
    prepare_confirmed_remote_disks(repo, state)?;
    run_backend(repo, state, true)
}

fn run_backend(repo: &Path, state: &InstallState, confirmed: bool) -> Result<u8> {
    let dotfiles_repo = normalized_dotfiles_repo(state.dotfiles_repo.as_deref());

    let mut command = Command::new(repo.join("install.sh"));
    command
        .current_dir(repo)
        .env("INSTALL_USER", &state.install_user)
        .env("DOTFILES_REPO", dotfiles_repo)
        .env("INSTALL_ROLE", state.role.title());
    if confirmed {
        command.env("NIXOS_INSTALL_ASSUME_YES", "1");
    }

    match state.scope {
        InstallScope::Remote => {
            command
                .arg("remote")
                .arg(state.role.title())
                .arg(&state.hostname)
                .arg(&state.remote);
        }
        InstallScope::Local => {
            command
                .arg("local")
                .arg(&state.hostname)
                .arg(&state.mountpoint);
        }
    }

    command.stdin(Stdio::inherit());
    command.stdout(Stdio::inherit());
    command.stderr(Stdio::inherit());
    exec_status(&mut command)
}

fn prepare_confirmed_remote_disks(
    repo: &Path,
    state: &InstallState,
) -> Result<Vec<DiskPrepareResult>> {
    if state.scope != InstallScope::Remote {
        return Ok(Vec::new());
    }

    let agent = agent_bootstrap::bootstrap_with_progress(repo, &state.remote, |message| {
        println!("agent bootstrap: {message}");
    })?;
    let agent_binary = agent.binary.to_string_lossy().to_string();
    prepare_confirmed_remote_disks_with_runner(state, |remote, disk| {
        agent_client::prepare_disk(remote, &agent_binary, disk)
    })
}

fn prepare_confirmed_remote_disks_with_runner(
    state: &InstallState,
    disk_preparer: impl Fn(&str, &str) -> Result<DiskPrepareResult>,
) -> Result<Vec<DiskPrepareResult>> {
    if state.scope != InstallScope::Remote {
        return Ok(Vec::new());
    }
    if state.disks.is_empty() {
        return Err("no remote install disks selected".to_string());
    }

    let mut results = Vec::new();
    for disk in &state.disks {
        println!("preparing remote disk through nx agent: {}", disk.path);
        let result = disk_preparer(&state.remote, &disk.path)?;
        if result.status != 0 {
            let detail = if result.stderr.is_empty() {
                format!("remote disk prep exited with {}", result.status)
            } else {
                format!(
                    "remote disk prep exited with {}: {}",
                    result.status, result.stderr
                )
            };
            return Err(format!("failed to prepare {}: {detail}", disk.path));
        }
        if !result.stdout.is_empty() {
            println!("{}", result.stdout);
        }
        results.push(result);
    }
    Ok(results)
}

fn validate_state(state: &InstallState) -> Result<()> {
    validate_hostname(&state.hostname)?;
    validate_username(&state.install_user)?;
    match state.scope {
        InstallScope::Remote => {
            if state.remote.trim().is_empty() {
                return Err("remote target is required".to_string());
            }
            if !state.remote.contains('@') {
                return Err(format!(
                    "remote target should look like user@host: {}",
                    state.remote
                ));
            }
        }
        InstallScope::Local => validate_mountpoint(&state.mountpoint)?,
    }
    Ok(())
}

fn normalized_dotfiles_repo(value: Option<&str>) -> &str {
    match value.map(str::trim) {
        None | Some("") | Some("skip") | Some("none") | Some("no") => "",
        Some(value) => value,
    }
}

fn write_host(repo: &Path, state: &InstallState) -> Result<()> {
    validate_hostname(&state.hostname)?;
    let file = repo.join("generated/host.nix");
    write_file(
        &file,
        &format!(
            r#"{{
  lib,
  modulesPath,
  ...
}}:

{{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  networking.hostName = lib.mkDefault "{}";

  bresilla.features.system.architecture = lib.mkDefault "unknown";
  bresilla.features.system.cpuVendor = lib.mkDefault "unknown";

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi = {{
    canTouchEfiVariables = lib.mkDefault true;
    efiSysMountPoint = lib.mkDefault "/boot/efi";
  }};
}}
"#,
            state.hostname
        ),
    )
}

fn write_user(repo: &Path, state: &InstallState) -> Result<()> {
    validate_username(&state.install_user)?;
    let file = repo.join("generated/user.nix");
    write_file(
        &file,
        &format!(
            r#"{{
  lib,
  ...
}}:

{{
  bresilla.user.name = lib.mkDefault "{}";
  bresilla.user.hashedPasswordFile = lib.mkDefault null;
}}
"#,
            state.install_user
        ),
    )
}

fn write_file(file: &Path, content: &str) -> Result<()> {
    if let Some(parent) = file.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
    }
    fs::write(file, content).map_err(|err| format!("failed to write {}: {err}", file.display()))
}

fn generated_nix_files(repo: &Path) -> [PathBuf; 3] {
    [
        repo.join("generated/disko.nix"),
        repo.join("generated/host.nix"),
        repo.join("generated/user.nix"),
    ]
}

fn validate_hostname(value: &str) -> Result<()> {
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

fn validate_username(value: &str) -> Result<()> {
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
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{
        normalized_dotfiles_repo, prepare_confirmed_remote_disks_with_runner, prepare_generated,
        validate_hostname, validate_username,
    };
    use crate::install_disk::DiskPrepareResult;
    use crate::install_state::{InstallScope, InstallState};

    #[test]
    fn validates_hostname_like_shell_installer() {
        assert!(validate_hostname("novo").is_ok());
        assert!(validate_hostname("nixos-box").is_ok());
        assert!(validate_hostname("-bad").is_err());
        assert!(validate_hostname("bad_underscore").is_err());
    }

    #[test]
    fn validates_username_like_shell_installer() {
        assert!(validate_username("bresilla").is_ok());
        assert!(validate_username("_svc").is_ok());
        assert!(validate_username("Bad").is_err());
        assert!(validate_username("bad.name").is_err());
    }

    #[test]
    fn prepares_generated_files_that_parse_as_nix() {
        let dir = temp_dir("generated");
        fs::create_dir_all(&dir).unwrap();
        prepare_generated(&dir, &InstallState::sample()).unwrap();

        assert!(dir.join("generated/disko.nix").is_file());
        assert!(dir.join("generated/host.nix").is_file());
        assert!(dir.join("generated/user.nix").is_file());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn normalizes_dotfiles_skip_values() {
        assert_eq!(normalized_dotfiles_repo(None), "");
        assert_eq!(normalized_dotfiles_repo(Some("skip")), "");
        assert_eq!(
            normalized_dotfiles_repo(Some("https://github.com/bresilla/dot.git")),
            "https://github.com/bresilla/dot.git"
        );
    }

    #[test]
    fn confirmed_remote_install_prepares_selected_disks() {
        let state = InstallState::sample();

        let results =
            prepare_confirmed_remote_disks_with_runner(&state, fake_disk_prepare).unwrap();

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].status, 0);
    }

    #[test]
    fn confirmed_local_install_does_not_prepare_remote_disks() {
        let mut state = InstallState::sample();
        state.scope = InstallScope::Local;

        let results =
            prepare_confirmed_remote_disks_with_runner(&state, panic_disk_prepare).unwrap();

        assert!(results.is_empty());
    }

    #[test]
    fn confirmed_remote_install_fails_when_disk_prepare_fails() {
        let state = InstallState::sample();

        let err =
            prepare_confirmed_remote_disks_with_runner(&state, failing_disk_prepare).unwrap_err();

        assert!(err.contains("failed to prepare /dev/nvme0n1"));
        assert!(err.contains("wipe failed"));
    }

    fn temp_dir(name: &str) -> PathBuf {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("nx-rs-install-{name}-{}-{now}", std::process::id()))
    }

    fn fake_disk_prepare(remote: &str, disk: &str) -> Result<DiskPrepareResult, String> {
        assert_eq!(remote, "nixos@10.10.10.7");
        assert_eq!(disk, "/dev/nvme0n1");
        Ok(DiskPrepareResult {
            status: 0,
            stdout: "prepared".to_string(),
            stderr: String::new(),
        })
    }

    fn failing_disk_prepare(_: &str, _: &str) -> Result<DiskPrepareResult, String> {
        Ok(DiskPrepareResult {
            status: 1,
            stdout: String::new(),
            stderr: "wipe failed".to_string(),
        })
    }

    fn panic_disk_prepare(_: &str, _: &str) -> Result<DiskPrepareResult, String> {
        panic!("local install should not prepare remote disks")
    }
}
