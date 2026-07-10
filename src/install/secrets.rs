use std::path::Path;
use std::process::Command;

use crate::Result;
use crate::{sops::metadata::SopsMetadata, yubikey_probe};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SecretCheck {
    pub ok: bool,
    pub detail: String,
}

/// Hash a plaintext login password with `mkpasswd -m yescrypt`, matching the
/// hash format the installer writes to `hashedPasswordFile`. Shared by the CLI
/// (`--password`) and the TUI password field.
pub fn hash_password(password: &str) -> Result<String> {
    use std::io::Write;
    use std::process::Stdio;

    if password.is_empty() {
        return Err("password is empty".to_string());
    }
    let mut child = Command::new("mkpasswd")
        .args(["-m", "yescrypt", "-s"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| format!("failed to run mkpasswd (is it installed?): {err}"))?;
    child
        .stdin
        .take()
        .ok_or_else(|| "failed to open mkpasswd stdin".to_string())?
        .write_all(format!("{password}\n").as_bytes())
        .map_err(|err| format!("failed to write password to mkpasswd: {err}"))?;
    let output = child
        .wait_with_output()
        .map_err(|err| format!("failed to wait for mkpasswd: {err}"))?;
    if !output.status.success() {
        return Err(format!(
            "mkpasswd failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let hash = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if hash.is_empty() {
        return Err("mkpasswd produced an empty hash".to_string());
    }
    Ok(hash)
}

pub fn check(repo: &Path) -> SecretCheck {
    match check_inner(repo) {
        Ok(detail) => SecretCheck { ok: true, detail },
        Err(detail) => SecretCheck { ok: false, detail },
    }
}

fn check_inner(repo: &Path) -> Result<String> {
    require_file(repo.join("host/.sops.yaml").as_path())?;
    require_file(repo.join("host/secrets/key.txt").as_path())?;
    let system = repo.join("host/secrets/system.yaml");
    require_file(&system)?;

    let metadata = SopsMetadata::load(&system)?;
    let recipients = yubikey_probe::recipients()?;
    let connected = recipients
        .recipients
        .iter()
        .flat_map(|recipient| recipient.all_recipients())
        .any(|recipient| metadata.recipients().contains(recipient));
    if !connected {
        return Err("connected YubiKey does not match secrets/system.yaml recipients".to_string());
    }

    let data_key = crate::sops::data_key::decrypt_first(&metadata, &recipients)?;
    let report = crate::sops::values::check_file(&system, &data_key)?;
    Ok(format!(
        "system.yaml decrypted={}/{} mac_decrypted={} mac_matches={}",
        report.decrypted_values, report.encrypted_values, report.mac_decrypted, report.mac_matches
    ))
}

fn require_file(path: &Path) -> Result<()> {
    if path.is_file() {
        Ok(())
    } else {
        Err(format!("missing required secret file: {}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::check;

    #[test]
    fn missing_repo_secret_files_fail_cleanly() {
        let result = check(Path::new("/definitely/missing/nox-secrets"));
        assert!(!result.ok);
        assert!(result.detail.contains("missing required secret file"));
    }
}
