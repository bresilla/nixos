use std::env;
use std::path::{Path, PathBuf};

use crate::Result;

pub fn find() -> Result<PathBuf> {
    if let Some(dir) = env::var_os("NX_REPO_DIR").map(PathBuf::from) {
        return validate(dir);
    }

    if let Ok(exe) = env::current_exe() {
        if let Some(found) = exe.parent().and_then(find_upwards) {
            return Ok(found);
        }
    }

    if let Ok(cwd) = env::current_dir() {
        if let Some(found) = find_upwards(&cwd) {
            return Ok(found);
        }
    }

    let etc = PathBuf::from("/etc/nixos");
    if is_repo(&etc) {
        return Ok(etc);
    }

    Err("could not find repo root containing flake.nix and install.sh".to_string())
}

fn validate(dir: PathBuf) -> Result<PathBuf> {
    if is_repo(&dir) {
        Ok(dir)
    } else {
        Err(format!(
            "NX_REPO_DIR does not look like this repo: {}",
            dir.display()
        ))
    }
}

fn find_upwards(start: &Path) -> Option<PathBuf> {
    let mut dir = start.to_path_buf();
    loop {
        if is_repo(&dir) {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

fn is_repo(path: &Path) -> bool {
    path.join("flake.nix").is_file() && path.join("install.sh").is_file()
}
