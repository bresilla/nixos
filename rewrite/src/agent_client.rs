use std::fs;
use std::io::{self, Write};
use std::path::Path;

use crate::agent::{
    self, AgentRequest, AgentResponse, CommandResult, FileWriteResult, ToolsCheckResult,
};
use crate::install_disk::DiskPrepareResult;
use crate::install_ssh::{self, RemoteCommandOutput};
use crate::Result;

const MAX_AGENT_FRAME_LEN: usize = 16 * 1024 * 1024;

pub struct AgentSession {
    transport: install_ssh::InteractiveCommand,
}

impl AgentSession {
    pub fn connect(remote: &str, agent_binary: &str) -> Result<Self> {
        let command = format!("{} agent", shell_single_quote(agent_binary));
        let transport = install_ssh::open_interactive_command(remote, &command)?;
        Ok(Self { transport })
    }

    pub fn request(&mut self, request: AgentRequest) -> Result<AgentResponse> {
        let mut input = Vec::new();
        agent::write_frame(&mut input, &request)?;
        self.transport.send(&input)?;

        self.read_response()
    }

    fn read_response(&mut self) -> Result<AgentResponse> {
        let length = self.transport.read_exact_stdout(4)?;
        let length = u32::from_be_bytes(
            length
                .try_into()
                .map_err(|_| "invalid agent frame length".to_string())?,
        ) as usize;
        if length > MAX_AGENT_FRAME_LEN {
            return Err(format!("agent frame too large: {length} bytes"));
        }
        let payload = self.transport.read_exact_stdout(length)?;
        postcard::from_bytes(&payload)
            .map_err(|err| format!("failed to decode agent frame payload ({length} bytes): {err}"))
    }

    pub fn ping(&mut self) -> Result<()> {
        match self.request(AgentRequest::Ping)? {
            AgentResponse::Pong => Ok(()),
            response => Err(format!("unexpected remote agent response: {response:?}")),
        }
    }

    pub fn prepare_disk(&mut self, disk: &str) -> Result<DiskPrepareResult> {
        match self.request(AgentRequest::DiskPrepare {
            disk: disk.to_string(),
        })? {
            AgentResponse::DiskPrepare { result } => Ok(result),
            AgentResponse::Error { message } => Err(message),
            response => Err(format!(
                "unexpected remote disk prepare response: {response:?}"
            )),
        }
    }

    pub fn run_command(
        &mut self,
        program: &str,
        args: &[String],
        stdin: &[u8],
    ) -> Result<CommandResult> {
        let mut input = Vec::new();
        agent::write_frame(
            &mut input,
            &AgentRequest::RunCommand {
                program: program.to_string(),
                args: args.to_vec(),
                stdin: stdin.to_vec(),
            },
        )?;
        self.transport.send(&input)?;

        let mut streamed_output = false;
        loop {
            match self.read_response()? {
                AgentResponse::Command { mut result } => {
                    if streamed_output {
                        result.stdout.clear();
                        result.stderr.clear();
                    }
                    return Ok(result);
                }
                AgentResponse::CommandProgress { stdout, stderr } => {
                    streamed_output = true;
                    if !stdout.is_empty() {
                        io::stdout()
                            .write_all(&stdout)
                            .map_err(|err| format!("failed to write command stdout: {err}"))?;
                        io::stdout()
                            .flush()
                            .map_err(|err| format!("failed to flush command stdout: {err}"))?;
                    }
                    if !stderr.is_empty() {
                        io::stderr()
                            .write_all(&stderr)
                            .map_err(|err| format!("failed to write command stderr: {err}"))?;
                        io::stderr()
                            .flush()
                            .map_err(|err| format!("failed to flush command stderr: {err}"))?;
                    }
                }
                AgentResponse::Error { message } => return Err(message),
                response => {
                    return Err(format!("unexpected remote command response: {response:?}"))
                }
            }
        }
    }

    pub fn run_command_env(
        &mut self,
        program: &str,
        args: &[String],
        stdin: &[u8],
        env: &[(String, String)],
    ) -> Result<CommandResult> {
        let mut input = Vec::new();
        agent::write_frame(
            &mut input,
            &AgentRequest::RunCommandEnv {
                program: program.to_string(),
                args: args.to_vec(),
                stdin: stdin.to_vec(),
                env: env.to_vec(),
            },
        )?;
        self.transport.send(&input)?;

        let mut streamed_output = false;
        loop {
            match self.read_response()? {
                AgentResponse::Command { mut result } => {
                    if streamed_output {
                        result.stdout.clear();
                        result.stderr.clear();
                    }
                    return Ok(result);
                }
                AgentResponse::CommandProgress { stdout, stderr } => {
                    streamed_output = true;
                    if !stdout.is_empty() {
                        io::stdout()
                            .write_all(&stdout)
                            .map_err(|err| format!("failed to write command stdout: {err}"))?;
                        io::stdout()
                            .flush()
                            .map_err(|err| format!("failed to flush command stdout: {err}"))?;
                    }
                    if !stderr.is_empty() {
                        io::stderr()
                            .write_all(&stderr)
                            .map_err(|err| format!("failed to write command stderr: {err}"))?;
                        io::stderr()
                            .flush()
                            .map_err(|err| format!("failed to flush command stderr: {err}"))?;
                    }
                }
                AgentResponse::Error { message } => return Err(message),
                response => {
                    return Err(format!(
                        "unexpected remote env command response: {response:?}"
                    ))
                }
            }
        }
    }

    pub fn tools_check(
        &mut self,
        required: &[String],
        require_passwordless_sudo: bool,
    ) -> Result<ToolsCheckResult> {
        match self.request(AgentRequest::ToolsCheck {
            required: required.to_vec(),
            require_passwordless_sudo,
        })? {
            AgentResponse::ToolsCheck { result } => Ok(result),
            AgentResponse::Error { message } => Err(message),
            response => Err(format!(
                "unexpected remote tools check response: {response:?}"
            )),
        }
    }

    pub fn write_file(
        &mut self,
        path: &str,
        bytes: &[u8],
        mode: Option<u32>,
        create_parent: bool,
    ) -> Result<FileWriteResult> {
        match self.request(AgentRequest::WriteFile {
            path: path.to_string(),
            bytes: bytes.to_vec(),
            mode,
            create_parent,
        })? {
            AgentResponse::WriteFile { result } => Ok(result),
            AgentResponse::Error { message } => Err(message),
            response => Err(format!(
                "unexpected remote file write response: {response:?}"
            )),
        }
    }

    pub fn sudo_write_file(
        &mut self,
        path: &str,
        bytes: &[u8],
        mode: u32,
        create_parent: bool,
    ) -> Result<FileWriteResult> {
        match self.request(AgentRequest::SudoWriteFile {
            path: path.to_string(),
            bytes: bytes.to_vec(),
            mode,
            create_parent,
        })? {
            AgentResponse::WriteFile { result } => Ok(result),
            AgentResponse::Error { message } => Err(message),
            response => Err(format!(
                "unexpected remote sudo file write response: {response:?}"
            )),
        }
    }

    pub fn disko_apply(&mut self, disko_file: &str) -> Result<CommandResult> {
        match self.request(AgentRequest::DiskoApply {
            disko_file: disko_file.to_string(),
        })? {
            AgentResponse::Command { result } => Ok(result),
            AgentResponse::Error { message } => Err(message),
            response => Err(format!("unexpected remote disko response: {response:?}")),
        }
    }

    pub fn config_copy(
        &mut self,
        source_dir: &str,
        role: &str,
        install_user: &str,
    ) -> Result<CommandResult> {
        match self.request(AgentRequest::ConfigCopy {
            source_dir: source_dir.to_string(),
            role: role.to_string(),
            install_user: install_user.to_string(),
        })? {
            AgentResponse::Command { result } => Ok(result),
            AgentResponse::Error { message } => Err(message),
            response => Err(format!(
                "unexpected remote config-copy response: {response:?}"
            )),
        }
    }

    pub fn network_route_cleanup(&mut self) -> Result<CommandResult> {
        match self.request(AgentRequest::NetworkRouteCleanup)? {
            AgentResponse::Command { result } => Ok(result),
            AgentResponse::Error { message } => Err(message),
            response => Err(format!(
                "unexpected remote network route cleanup response: {response:?}"
            )),
        }
    }

    pub fn storage_overwrite(&mut self, vg_name: &str) -> Result<CommandResult> {
        match self.request(AgentRequest::StorageOverwrite {
            vg_name: vg_name.to_string(),
        })? {
            AgentResponse::Command { result } => Ok(result),
            AgentResponse::Error { message } => Err(message),
            response => Err(format!(
                "unexpected remote storage overwrite response: {response:?}"
            )),
        }
    }

    pub fn dotfiles_run(
        &mut self,
        dotfiles_repo: &str,
        install_user: &str,
        github_token: &[u8],
    ) -> Result<CommandResult> {
        let mut input = Vec::new();
        agent::write_frame(
            &mut input,
            &AgentRequest::DotfilesRun {
                dotfiles_repo: dotfiles_repo.to_string(),
                install_user: install_user.to_string(),
                github_token: github_token.to_vec(),
            },
        )?;
        self.transport.send(&input)?;

        let mut streamed_output = false;
        loop {
            match self.read_response()? {
                AgentResponse::Command { mut result } => {
                    if streamed_output {
                        result.stdout.clear();
                        result.stderr.clear();
                    }
                    return Ok(result);
                }
                AgentResponse::CommandProgress { stdout, stderr } => {
                    streamed_output = true;
                    if !stdout.is_empty() {
                        io::stdout()
                            .write_all(&stdout)
                            .map_err(|err| format!("failed to write dotfiles stdout: {err}"))?;
                        io::stdout()
                            .flush()
                            .map_err(|err| format!("failed to flush dotfiles stdout: {err}"))?;
                    }
                    if !stderr.is_empty() {
                        io::stderr()
                            .write_all(&stderr)
                            .map_err(|err| format!("failed to write dotfiles stderr: {err}"))?;
                        io::stderr()
                            .flush()
                            .map_err(|err| format!("failed to flush dotfiles stderr: {err}"))?;
                    }
                }
                AgentResponse::Error { message } => return Err(message),
                response => {
                    return Err(format!(
                        "unexpected remote dotfiles-run response: {response:?}"
                    ))
                }
            }
        }
    }

    pub fn schedule_reboot(&mut self, delay_secs: u64) -> Result<u64> {
        match self.request(AgentRequest::ScheduleReboot { delay_secs })? {
            AgentResponse::RebootScheduled { delay_secs } => Ok(delay_secs),
            AgentResponse::Error { message } => Err(message),
            response => Err(format!(
                "unexpected remote reboot schedule response: {response:?}"
            )),
        }
    }

    pub fn close(self) -> Result<RemoteCommandOutput> {
        self.transport.close()
    }
}

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

#[allow(dead_code)]
pub fn request(remote: &str, agent_binary: &str, request: AgentRequest) -> Result<AgentResponse> {
    let mut session = AgentSession::connect(remote, agent_binary)?;
    let response = session.request(request)?;
    let _ = session.close();
    Ok(response)
}

#[allow(dead_code)]
pub fn prepare_disk(remote: &str, agent_binary: &str, disk: &str) -> Result<DiskPrepareResult> {
    let mut session = AgentSession::connect(remote, agent_binary)?;
    let result = session.prepare_disk(disk)?;
    let _ = session.close();
    Ok(result)
}

#[allow(dead_code)]
pub fn run_command(
    remote: &str,
    agent_binary: &str,
    program: &str,
    args: &[String],
    stdin: &[u8],
) -> Result<CommandResult> {
    let mut session = AgentSession::connect(remote, agent_binary)?;
    let result = session.run_command(program, args, stdin)?;
    let _ = session.close();
    Ok(result)
}

#[allow(dead_code)]
pub fn tools_check(
    remote: &str,
    agent_binary: &str,
    required: &[String],
    require_passwordless_sudo: bool,
) -> Result<ToolsCheckResult> {
    let mut session = AgentSession::connect(remote, agent_binary)?;
    let result = session.tools_check(required, require_passwordless_sudo)?;
    let _ = session.close();
    Ok(result)
}

#[allow(dead_code)]
pub fn write_file(
    remote: &str,
    agent_binary: &str,
    path: &str,
    bytes: &[u8],
    mode: Option<u32>,
    create_parent: bool,
) -> Result<FileWriteResult> {
    let mut session = AgentSession::connect(remote, agent_binary)?;
    let result = session.write_file(path, bytes, mode, create_parent)?;
    let _ = session.close();
    Ok(result)
}

#[allow(dead_code)]
pub fn sudo_write_file(
    remote: &str,
    agent_binary: &str,
    path: &str,
    bytes: &[u8],
    mode: u32,
    create_parent: bool,
) -> Result<FileWriteResult> {
    let mut session = AgentSession::connect(remote, agent_binary)?;
    let result = session.sudo_write_file(path, bytes, mode, create_parent)?;
    let _ = session.close();
    Ok(result)
}

#[cfg(test)]
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
    fn sends_file_write_request_to_remote_agent() {
        let response = request_with_runner(
            "nixos@10.10.10.7",
            "/tmp/nx-rs",
            AgentRequest::WriteFile {
                path: "/tmp/config.nix".to_string(),
                bytes: b"config".to_vec(),
                mode: Some(0o644),
                create_parent: true,
            },
            file_write_runner,
        )
        .unwrap();

        match response {
            AgentResponse::WriteFile { result } => {
                assert_eq!(result.path, "/tmp/config.nix");
                assert_eq!(result.bytes_written, 6);
            }
            response => panic!("unexpected response: {response:?}"),
        }
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

    fn file_write_runner(
        remote: &str,
        command: &str,
        mut stdin: &[u8],
    ) -> Result<RemoteCommandOutput, String> {
        assert_eq!(remote, "nixos@10.10.10.7");
        assert_eq!(command, "'/tmp/nx-rs' agent");
        let request = agent::read_frame::<_, AgentRequest>(&mut stdin)
            .unwrap()
            .unwrap();
        match request {
            AgentRequest::WriteFile {
                path,
                bytes,
                mode,
                create_parent,
            } => {
                assert_eq!(path, "/tmp/config.nix");
                assert_eq!(bytes, b"config");
                assert_eq!(mode, Some(0o644));
                assert!(create_parent);
            }
            request => panic!("unexpected request: {request:?}"),
        }

        let mut stdout = Vec::new();
        agent::write_frame(
            &mut stdout,
            &AgentResponse::WriteFile {
                result: agent::FileWriteResult {
                    path: "/tmp/config.nix".to_string(),
                    bytes_written: 6,
                },
            },
        )
        .unwrap();
        Ok(RemoteCommandOutput {
            status: 0,
            stdout,
            stderr: Vec::new(),
        })
    }
}
