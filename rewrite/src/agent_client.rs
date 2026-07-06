use std::fs;
use std::path::Path;

use crate::agent::{self, AgentRequest, AgentResponse};
use crate::install_disk::DiskPrepareResult;
use crate::install_ssh::{self, RemoteCommandOutput};
use crate::Result;

pub fn upload(remote: &str, local_binary: &Path, remote_binary: &str) -> Result<()> {
    upload_with_runner(
        remote,
        local_binary,
        remote_binary,
        install_ssh::run_command_with_stdin,
    )
}

fn upload_with_runner(
    remote: &str,
    local_binary: &Path,
    remote_binary: &str,
    runner: fn(&str, &str, &[u8]) -> Result<RemoteCommandOutput>,
) -> Result<()> {
    let bytes = fs::read(local_binary)
        .map_err(|err| format!("failed to read {}: {err}", local_binary.display()))?;
    if bytes.is_empty() {
        return Err(format!("{} is empty", local_binary.display()));
    }
    if remote.trim().is_empty() {
        return Err("remote target is empty".to_string());
    }
    if remote_binary.trim().is_empty() {
        return Err("remote agent binary path is empty".to_string());
    }

    let remote_path = shell_single_quote(remote_binary);
    let command = format!(
        "tmp={remote_path}.tmp.$$; umask 077; cat > \"$tmp\" && chmod 700 \"$tmp\" && mv \"$tmp\" {remote_path}"
    );
    let output = runner(remote.trim(), &command, &bytes)?;
    if output.status == 0 {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(if stderr.is_empty() {
            format!("remote agent upload exited with {}", output.status)
        } else {
            format!(
                "remote agent upload exited with {}: {stderr}",
                output.status
            )
        })
    }
}

pub fn request(remote: &str, agent_binary: &str, request: AgentRequest) -> Result<AgentResponse> {
    request_with_runner(
        remote,
        agent_binary,
        request,
        install_ssh::run_command_with_stdin,
    )
}

pub fn prepare_disk(remote: &str, agent_binary: &str, disk: &str) -> Result<DiskPrepareResult> {
    match request(
        remote,
        agent_binary,
        AgentRequest::DiskPrepare {
            disk: disk.to_string(),
        },
    )? {
        AgentResponse::DiskPrepare { result } => Ok(result),
        AgentResponse::Error { message } => Err(message),
        response => Err(format!(
            "unexpected remote disk prepare response: {response:?}"
        )),
    }
}

fn request_with_runner(
    remote: &str,
    agent_binary: &str,
    request: AgentRequest,
    runner: fn(&str, &str, &[u8]) -> Result<RemoteCommandOutput>,
) -> Result<AgentResponse> {
    let mut input = Vec::new();
    agent::write_frame(&mut input, &request)?;

    let command = format!("{} agent", shell_single_quote(agent_binary));
    let output = runner(remote, &command, &input)?;
    if output.status != 0 {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if stderr.is_empty() {
            format!("remote agent exited with {}", output.status)
        } else {
            format!("remote agent exited with {}: {stderr}", output.status)
        });
    }

    let mut stdout = output.stdout.as_slice();
    agent::read_frame::<_, AgentResponse>(&mut stdout)?
        .ok_or_else(|| "remote agent returned no response".to_string())
}

fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::{request_with_runner, upload_with_runner};
    use crate::agent::{self, AgentRequest, AgentResponse};
    use crate::install_ssh::RemoteCommandOutput;
    use std::fs;

    #[test]
    fn sends_postcard_frame_to_remote_agent_command() {
        let response = request_with_runner(
            "nixos@10.10.10.7",
            "/tmp/nx-rs",
            AgentRequest::Ping,
            fake_runner,
        )
        .unwrap();

        assert_eq!(response, AgentResponse::Pong);
    }

    #[test]
    fn reports_remote_agent_failure() {
        let err = request_with_runner(
            "nixos@10.10.10.7",
            "/tmp/nx-rs",
            AgentRequest::Ping,
            failing_runner,
        )
        .unwrap_err();

        assert!(err.contains("remote agent exited with 127"));
        assert!(err.contains("not found"));
    }

    #[test]
    fn uploads_local_binary_to_remote_path() {
        let path = std::env::temp_dir().join(format!("nx-rs-agent-upload-{}", std::process::id()));
        fs::write(&path, b"binary").unwrap();

        upload_with_runner("nixos@10.10.10.7", &path, "/tmp/nx-rs", upload_runner).unwrap();

        fs::remove_file(path).unwrap();
    }

    fn fake_runner(
        remote: &str,
        command: &str,
        mut stdin: &[u8],
    ) -> Result<RemoteCommandOutput, String> {
        assert_eq!(remote, "nixos@10.10.10.7");
        assert_eq!(command, "'/tmp/nx-rs' agent");
        let request = agent::read_frame::<_, AgentRequest>(&mut stdin)
            .unwrap()
            .unwrap();
        assert_eq!(request, AgentRequest::Ping);

        let mut stdout = Vec::new();
        agent::write_frame(&mut stdout, &AgentResponse::Pong).unwrap();
        Ok(RemoteCommandOutput {
            status: 0,
            stdout,
            stderr: Vec::new(),
        })
    }

    fn failing_runner(_: &str, _: &str, _: &[u8]) -> Result<RemoteCommandOutput, String> {
        Ok(RemoteCommandOutput {
            status: 127,
            stdout: Vec::new(),
            stderr: b"not found\n".to_vec(),
        })
    }

    fn upload_runner(
        remote: &str,
        command: &str,
        stdin: &[u8],
    ) -> Result<RemoteCommandOutput, String> {
        assert_eq!(remote, "nixos@10.10.10.7");
        assert!(command.contains("cat > \"$tmp\""));
        assert!(command.contains("chmod 700 \"$tmp\""));
        assert!(command.contains("mv \"$tmp\" '/tmp/nx-rs'"));
        assert_eq!(stdin, b"binary");
        Ok(RemoteCommandOutput {
            status: 0,
            stdout: Vec::new(),
            stderr: Vec::new(),
        })
    }
}
