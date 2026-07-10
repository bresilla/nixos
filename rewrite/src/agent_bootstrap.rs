use std::path::{Path, PathBuf};
use std::process::Command;

use crate::Result;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrappedAgent {
    pub store_path: PathBuf,
    pub binary: PathBuf,
}

pub fn bootstrap_with_progress(
    repo: &Path,
    remote: &str,
    mut progress: impl FnMut(&str),
) -> Result<BootstrappedAgent> {
    progress("building local nox agent with Nix");
    let store_path = build(repo)?;
    progress("copying nox Nix closure to target");
    copy(remote, &store_path)?;
    progress("remote nox agent is ready");
    Ok(BootstrappedAgent {
        binary: store_path.join("bin/nox"),
        store_path,
    })
}

pub fn build(repo: &Path) -> Result<PathBuf> {
    let output = Command::new("nix")
        .arg("--extra-experimental-features")
        .arg("nix-command flakes")
        .arg("build")
        .arg("--impure")
        .arg("--expr")
        .arg(build_expr(repo))
        .arg("--no-link")
        .arg("--print-out-paths")
        .output()
        .map_err(|err| format!("failed to run nix build: {err}"))?;

    if !output.status.success() {
        return Err(command_error("nix build", &output));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let path = stdout
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .ok_or_else(|| "nix build did not print a store path".to_string())?;

    Ok(PathBuf::from(path))
}

pub fn copy(remote: &str, store_path: &Path) -> Result<()> {
    if remote.trim().is_empty() {
        return Err("remote target is empty".to_string());
    }
    let output = Command::new("nix")
        .arg("--extra-experimental-features")
        .arg("nix-command flakes")
        .arg("copy")
        .arg("--to")
        .arg(format!("ssh://{}", remote.trim()))
        .arg(store_path)
        .output()
        .map_err(|err| format!("failed to run nix copy: {err}"))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(command_error("nix copy", &output))
    }
}

fn build_expr(repo: &Path) -> String {
    let flake_ref = nix_flake_ref(repo);
    let package = format!("{}/rewrite/package.nix", repo.display());
    format!(
        "let flake = builtins.getFlake {flake_ref}; \
         pkgs = import flake.inputs.nixpkgs {{ system = builtins.currentSystem; }}; \
         in pkgs.callPackage {package} {{}}"
    )
}

fn nix_flake_ref(path: &Path) -> String {
    let value = format!("path:{}", path.display());
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn command_error(name: &str, output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let detail = if !stderr.is_empty() { stderr } else { stdout };
    if detail.is_empty() {
        format!("{name} exited with {}", output.status)
    } else {
        format!("{name} exited with {}: {detail}", output.status)
    }
}

#[cfg(test)]
mod tests {
    use super::build_expr;
    use std::path::Path;

    #[test]
    fn build_expr_points_at_rewrite_package() {
        let expr = build_expr(Path::new("/home/me/nixos"));
        assert!(expr.contains("builtins.getFlake \"path:/home/me/nixos\""));
        assert!(expr.contains("pkgs.callPackage /home/me/nixos/rewrite/package.nix {}"));
    }
}
