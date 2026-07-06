use std::io::{self, ErrorKind, Read, Write};

use serde::{Deserialize, Serialize};

use crate::install_disk::{self, DiskInfo, DiskPrepareResult};
use crate::install_state::InstallScope;
use crate::Result;

const MAX_FRAME_LEN: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentRequest {
    Ping,
    DiskScan,
    DiskPrepare { disk: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentResponse {
    Pong,
    DiskScan { disks: Vec<DiskInfo> },
    DiskPrepare { result: DiskPrepareResult },
    Error { message: String },
}

pub fn run_stdio() -> Result<u8> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    run(stdin.lock(), stdout.lock())
}

pub fn run<R: Read, W: Write>(mut reader: R, mut writer: W) -> Result<u8> {
    loop {
        let request = match read_frame::<_, AgentRequest>(&mut reader) {
            Ok(Some(request)) => request,
            Ok(None) => break,
            Err(err) => {
                write_frame(
                    &mut writer,
                    &AgentResponse::Error {
                        message: err.clone(),
                    },
                )?;
                return Err(err);
            }
        };

        let response = handle_request(request);
        write_frame(&mut writer, &response)?;
        writer
            .flush()
            .map_err(|err| format!("failed to flush agent response: {err}"))?;
    }
    Ok(0)
}

fn handle_request(request: AgentRequest) -> AgentResponse {
    match request {
        AgentRequest::Ping => AgentResponse::Pong,
        AgentRequest::DiskScan => match install_disk::discover(InstallScope::Local, "") {
            Ok(disks) => AgentResponse::DiskScan { disks },
            Err(err) => AgentResponse::Error { message: err },
        },
        AgentRequest::DiskPrepare { disk } => match install_disk::local_prepare(&disk) {
            Ok(result) => AgentResponse::DiskPrepare { result },
            Err(err) => AgentResponse::Error { message: err },
        },
    }
}

pub fn write_frame<W: Write, T: Serialize>(writer: &mut W, value: &T) -> Result<()> {
    let payload =
        postcard::to_stdvec(value).map_err(|err| format!("failed to encode agent frame: {err}"))?;
    if payload.len() > MAX_FRAME_LEN {
        return Err(format!("agent frame too large: {} bytes", payload.len()));
    }
    writer
        .write_all(&(payload.len() as u32).to_be_bytes())
        .map_err(|err| format!("failed to write agent frame length: {err}"))?;
    writer
        .write_all(&payload)
        .map_err(|err| format!("failed to write agent frame payload: {err}"))
}

pub fn read_frame<R: Read, T: for<'de> Deserialize<'de>>(reader: &mut R) -> Result<Option<T>> {
    let mut length = [0u8; 4];
    match reader.read_exact(&mut length) {
        Ok(()) => {}
        Err(err) if err.kind() == ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(format!("failed to read agent frame length: {err}")),
    }

    let length = u32::from_be_bytes(length) as usize;
    if length > MAX_FRAME_LEN {
        return Err(format!("agent frame too large: {length} bytes"));
    }

    let mut payload = vec![0u8; length];
    reader
        .read_exact(&mut payload)
        .map_err(|err| format!("failed to read agent frame payload: {err}"))?;
    postcard::from_bytes(&payload)
        .map(Some)
        .map_err(|err| format!("failed to decode agent frame payload ({length} bytes): {err}"))
}

#[cfg(test)]
mod tests {
    use super::{read_frame, run, write_frame, AgentRequest, AgentResponse};

    #[test]
    fn frame_round_trip() {
        let request = AgentRequest::DiskPrepare {
            disk: "/dev/nvme0n1".to_string(),
        };
        let mut bytes = Vec::new();

        write_frame(&mut bytes, &request).unwrap();
        let decoded = read_frame::<_, AgentRequest>(&mut bytes.as_slice())
            .unwrap()
            .unwrap();

        assert_eq!(decoded, request);
    }

    #[test]
    fn ping_returns_pong() {
        let mut input = Vec::new();
        write_frame(&mut input, &AgentRequest::Ping).unwrap();
        let mut output = Vec::new();

        run(input.as_slice(), &mut output).unwrap();
        let response = read_frame::<_, AgentResponse>(&mut output.as_slice())
            .unwrap()
            .unwrap();

        assert_eq!(response, AgentResponse::Pong);
    }

    #[test]
    fn eof_without_frame_exits_cleanly() {
        let mut output = Vec::new();

        let code = run([].as_slice(), &mut output).unwrap();

        assert_eq!(code, 0);
        assert!(output.is_empty());
    }
}
