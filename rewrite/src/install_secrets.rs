use std::path::Path;

use crate::{sops_data_key, sops_metadata::SopsMetadata, sops_values, yubikey_probe, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SecretCheck {
    pub ok: bool,
    pub detail: String,
}

pub fn check(repo: &Path) -> SecretCheck {
    match check_inner(repo) {
        Ok(detail) => SecretCheck { ok: true, detail },
        Err(detail) => SecretCheck { ok: false, detail },
    }
}

fn check_inner(repo: &Path) -> Result<String> {
    require_file(repo.join(".sops.yaml").as_path())?;
    require_file(repo.join("secrets/key.txt").as_path())?;
    let system = repo.join("secrets/system.yaml");
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

    let data_key = sops_data_key::decrypt_first(&metadata, &recipients)?;
    let report = sops_values::check_file(&system, &data_key)?;
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
