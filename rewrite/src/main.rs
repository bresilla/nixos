use std::ffi::OsString;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use clap::{Args, Parser, Subcommand};

mod agent;
mod agent_bootstrap;
mod agent_client;
mod edit;
mod generate;
mod install_confirm;
mod install_disk;
mod install_disko;
mod install_exec;
mod install_preflight;
mod install_secrets;
mod install_ssh;
mod install_state;
mod install_ui;
mod install_wizard;
mod nix_ast;
mod repo;
mod sops_config;
mod sops_data_key;
mod sops_edit;
mod sops_metadata;
mod sops_unwrap;
mod sops_values;
mod ui;
mod yubikey_probe;

type Result<T> = std::result::Result<T, String>;

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code),
        Err(err) => {
            eprintln!("error: {err}");
            ExitCode::from(1)
        }
    }
}

fn run() -> Result<u8> {
    let cli = Cli::parse();

    match cli.command {
        CommandName::Install(args) => {
            let repo = repo::find()?;
            if args.args.is_empty() {
                return install_ui::run(&repo, true);
            }
            let mut command = Command::new(repo.join("install.sh"));
            command.current_dir(&repo).args(args.args);
            exec_status(&mut command)
        }
        CommandName::Generate(args) => {
            let repo = repo::find()?;
            generate::dispatch(
                &repo,
                generate::Options {
                    role: args.role,
                    check_only: args.check_only,
                },
            )
        }
        CommandName::Check(args) => {
            let repo = repo::find()?;
            generate::dispatch(
                &repo,
                generate::Options {
                    role: args.role,
                    check_only: true,
                },
            )
        }
        CommandName::Edit => {
            let repo = repo::find()?;
            edit::dispatch(&repo)
        }
        CommandName::Status => {
            let repo = repo::find()?;
            let mut command = Command::new("git");
            command.current_dir(&repo).arg("status").arg("--short");
            exec_status(&mut command)
        }
        CommandName::Agent => agent::run_stdio(),
        CommandName::AgentPing => agent_ping_dispatch(),
        CommandName::AgentRemotePing(args) => {
            agent_remote_ping_dispatch(&args.remote, &args.agent_binary)
        }
        CommandName::AgentRemoteDiskScan(args) => {
            agent_remote_disk_scan_dispatch(&args.remote, &args.agent_binary)
        }
        CommandName::AgentUpload(args) => agent_upload_dispatch(&args),
        CommandName::AgentBootstrapPing(args) => agent_bootstrap_ping_dispatch(&args),
        CommandName::AgentNixBootstrapPing(args) => {
            let repo = repo::find()?;
            agent_nix_bootstrap_ping_dispatch(&repo, &args.remote)
        }
        CommandName::AgentNixBootstrapDiskScan(args) => {
            let repo = repo::find()?;
            agent_nix_bootstrap_disk_scan_dispatch(&repo, &args.remote)
        }
        CommandName::InstallPreview => {
            let repo = repo::find()?;
            install_ui::run(&repo, false)
        }
        CommandName::DiskScan(args) => disk_scan_dispatch(args.remote),
        CommandName::DiskPrepPreview(args) => disk_prep_preview_dispatch(&args.disk),
        CommandName::Preflight => {
            let repo = repo::find()?;
            preflight_dispatch(&repo)
        }
        CommandName::SecretsCheck => {
            let repo = repo::find()?;
            secrets_check_dispatch(&repo)
        }
        CommandName::SshCheck(args) => ssh_check_dispatch(&args.remote),
        CommandName::SopsRule(args) => {
            let repo = repo::find()?;
            sops_rule_dispatch(&repo, &args.file)
        }
        CommandName::SopsInfo(args) => sops_info_dispatch(
            &args.file,
            args.stanzas,
            args.match_yubikey,
            args.unwrap_check,
            args.unwrap_file_key,
            args.unwrap_data_key,
            args.check_values,
        ),
        CommandName::NixParse(args) => nix_parse_dispatch(&args.file),
        CommandName::Yubikey { command } => yubikey_dispatch(command),
    }
}

#[derive(Parser)]
#[command(name = "nx-rs", version, about = "NixOS repo control tool")]
struct Cli {
    #[command(subcommand)]
    command: CommandName,
}

#[derive(Subcommand)]
enum CommandName {
    /// Run the clean installer.
    Install(PassthroughArgs),
    /// Apply this system flake.
    Generate(GenerateArgs),
    /// Validate the current role.
    Check(CheckArgs),
    /// Pick a file to edit.
    Edit,
    /// Show git status.
    Status,
    /// Run remote-side nx agent over framed stdin/stdout.
    #[command(hide = true)]
    Agent,
    /// Exercise the framed agent protocol locally.
    #[command(hide = true)]
    AgentPing,
    /// Ping a remote nx agent over russh.
    #[command(hide = true)]
    AgentRemotePing(AgentRemoteArgs),
    /// Ask a remote nx agent to scan disks over russh.
    #[command(hide = true)]
    AgentRemoteDiskScan(AgentRemoteArgs),
    /// Upload this binary as the remote nx agent.
    #[command(hide = true)]
    AgentUpload(AgentUploadArgs),
    /// Upload this binary, then ping the remote nx agent.
    #[command(hide = true)]
    AgentBootstrapPing(AgentUploadArgs),
    /// Build this binary with Nix, copy the closure, then ping the remote nx agent.
    #[command(hide = true)]
    AgentNixBootstrapPing(SshCheckArgs),
    /// Build this binary with Nix, copy the closure, then scan disks through the remote nx agent.
    #[command(hide = true)]
    AgentNixBootstrapDiskScan(SshCheckArgs),
    /// Preview the Rust install wizard UI.
    #[command(hide = true)]
    InstallPreview,
    /// Scan install disks with lsblk JSON.
    #[command(hide = true)]
    DiskScan(DiskScanArgs),
    /// Print the remote disk preparation command without running it.
    #[command(hide = true)]
    DiskPrepPreview(DiskPrepPreviewArgs),
    /// Run Rust install preflight on the draft state.
    #[command(hide = true)]
    Preflight,
    /// Check native YubiKey/SOPS system secrets.
    #[command(hide = true)]
    SecretsCheck,
    /// Check SSH key auth for a remote installer target.
    #[command(hide = true)]
    SshCheck(SshCheckArgs),
    /// Show the .sops.yaml rule for a secret file.
    #[command(hide = true)]
    SopsRule(SopsRuleArgs),
    /// Show SOPS metadata for an encrypted file.
    #[command(hide = true)]
    SopsInfo(SopsInfoArgs),
    /// Parse a Nix file with rnix.
    #[command(hide = true)]
    NixParse(NixParseArgs),
    /// Probe YubiKey readers with yubikey.rs.
    #[command(hide = true)]
    Yubikey {
        #[command(subcommand)]
        command: YubikeyCommand,
    },
}

#[derive(Args)]
#[command(disable_help_flag = true)]
struct PassthroughArgs {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    args: Vec<OsString>,
}

#[derive(Args)]
struct GenerateArgs {
    #[arg(long, value_parser = ["laptop", "server"])]
    role: Option<String>,
    #[arg(long)]
    check_only: bool,
}

#[derive(Args)]
struct CheckArgs {
    #[arg(long, value_parser = ["laptop", "server"])]
    role: Option<String>,
}

#[derive(Args)]
struct NixParseArgs {
    file: PathBuf,
}

#[derive(Args)]
struct SopsRuleArgs {
    file: PathBuf,
}

#[derive(Args)]
struct DiskScanArgs {
    #[arg(long)]
    remote: Option<String>,
}

#[derive(Args)]
struct DiskPrepPreviewArgs {
    #[arg(long)]
    disk: String,
}

#[derive(Args)]
struct AgentRemoteArgs {
    #[arg(long)]
    remote: String,
    #[arg(long, default_value = "/tmp/nx-rs")]
    agent_binary: String,
}

#[derive(Args)]
struct AgentUploadArgs {
    #[arg(long)]
    remote: String,
    #[arg(long, default_value = "/tmp/nx-rs")]
    agent_binary: String,
    #[arg(long)]
    local_binary: Option<PathBuf>,
}

#[derive(Args)]
struct SshCheckArgs {
    #[arg(long)]
    remote: String,
}

#[derive(Args)]
struct SopsInfoArgs {
    #[arg(long)]
    stanzas: bool,
    #[arg(long)]
    match_yubikey: bool,
    #[arg(long)]
    unwrap_check: bool,
    #[arg(long)]
    unwrap_file_key: bool,
    #[arg(long)]
    unwrap_data_key: bool,
    #[arg(long)]
    check_values: bool,
    file: PathBuf,
}

#[derive(Subcommand)]
enum YubikeyCommand {
    /// Show PC/SC readers visible to yubikey.rs.
    Status,
    /// List age-compatible recipients from YubiKey retired PIV slots.
    Recipients,
}

fn exec_status(command: &mut Command) -> Result<u8> {
    let status = command
        .status()
        .map_err(|err| format!("failed to run {:?}: {err}", command.get_program()))?;
    Ok(status.code().unwrap_or(1) as u8)
}

fn nix_parse_dispatch(path: &Path) -> Result<u8> {
    let report = nix_ast::parse_file(path)?;
    if report.is_ok() {
        println!("nix parse: ok ({} syntax nodes)", report.node_count);
        return Ok(0);
    }

    eprintln!("nix parse: {} error(s)", report.errors.len());
    for error in report.errors {
        eprintln!("  {error}");
    }
    Ok(1)
}

fn disk_scan_dispatch(remote: Option<String>) -> Result<u8> {
    let (scope, remote_value) = match remote {
        Some(remote) => (install_state::InstallScope::Remote, remote),
        None => (install_state::InstallScope::Local, String::new()),
    };
    let disks = install_disk::discover(scope, &remote_value)?;
    println!("install disks:");
    for disk in disks {
        match disk.model {
            Some(model) => println!("  {}  {}G  {}", disk.path, disk.size_gib, model),
            None => println!("  {}  {}G", disk.path, disk.size_gib),
        }
    }
    Ok(0)
}

fn agent_ping_dispatch() -> Result<u8> {
    let mut input = Vec::new();
    agent::write_frame(&mut input, &agent::AgentRequest::Ping)?;
    let mut output = Vec::new();
    agent::run(Cursor::new(input), &mut output)?;
    match agent::read_frame::<_, agent::AgentResponse>(&mut output.as_slice())? {
        Some(agent::AgentResponse::Pong) => {
            println!("agent: pong");
            Ok(0)
        }
        Some(response) => Err(format!("unexpected agent response: {response:?}")),
        None => Err("agent returned no response".to_string()),
    }
}

fn agent_remote_ping_dispatch(remote: &str, agent_binary: &str) -> Result<u8> {
    match agent_client::request(remote, agent_binary, agent::AgentRequest::Ping)? {
        agent::AgentResponse::Pong => {
            println!("remote agent: pong");
            Ok(0)
        }
        response => Err(format!("unexpected remote agent response: {response:?}")),
    }
}

fn agent_remote_disk_scan_dispatch(remote: &str, agent_binary: &str) -> Result<u8> {
    match agent_client::request(remote, agent_binary, agent::AgentRequest::DiskScan)? {
        agent::AgentResponse::DiskScan { disks } => {
            println!("remote agent disks:");
            for disk in disks {
                match disk.model {
                    Some(model) => println!("  {}  {}G  {}", disk.path, disk.size_gib, model),
                    None => println!("  {}  {}G", disk.path, disk.size_gib),
                }
            }
            Ok(0)
        }
        agent::AgentResponse::Error { message } => Err(message),
        response => Err(format!("unexpected remote agent response: {response:?}")),
    }
}

fn agent_upload_dispatch(args: &AgentUploadArgs) -> Result<u8> {
    let local_binary = local_agent_binary(args.local_binary.as_deref())?;
    agent_client::upload(&args.remote, &local_binary, &args.agent_binary)?;
    println!(
        "uploaded agent: {} -> {}:{}",
        local_binary.display(),
        args.remote,
        args.agent_binary
    );
    Ok(0)
}

fn agent_bootstrap_ping_dispatch(args: &AgentUploadArgs) -> Result<u8> {
    agent_upload_dispatch(args)?;
    agent_remote_ping_dispatch(&args.remote, &args.agent_binary)
}

fn agent_nix_bootstrap_ping_dispatch(repo: &Path, remote: &str) -> Result<u8> {
    let agent = agent_bootstrap::bootstrap_with_progress(repo, remote, |message| {
        println!("bootstrap: {message}");
    })?;
    println!("bootstrapped agent: {}", agent.binary.display());
    agent_remote_ping_dispatch(remote, &agent.binary.to_string_lossy())
}

fn agent_nix_bootstrap_disk_scan_dispatch(repo: &Path, remote: &str) -> Result<u8> {
    let agent = agent_bootstrap::bootstrap_with_progress(repo, remote, |message| {
        println!("bootstrap: {message}");
    })?;
    println!("bootstrapped agent: {}", agent.binary.display());
    agent_remote_disk_scan_dispatch(remote, &agent.binary.to_string_lossy())
}

fn local_agent_binary(override_path: Option<&Path>) -> Result<PathBuf> {
    match override_path {
        Some(path) => Ok(path.to_path_buf()),
        None => std::env::current_exe()
            .map_err(|err| format!("failed to resolve current executable: {err}")),
    }
}

fn disk_prep_preview_dispatch(disk: &str) -> Result<u8> {
    println!("{}", install_disk::remote_prepare_preview(disk)?);
    Ok(0)
}

fn preflight_dispatch(repo: &Path) -> Result<u8> {
    let state = install_state::InstallState::draft();
    let report = install_preflight::run(repo, &state);
    for check in &report.checks {
        let marker = match check.status {
            install_preflight::PreflightStatus::Pass => "ok",
            install_preflight::PreflightStatus::Fail => "fail",
        };
        println!("{marker}: {} - {}", check.name, check.detail);
    }
    Ok(if report.pass() { 0 } else { 1 })
}

fn secrets_check_dispatch(repo: &Path) -> Result<u8> {
    let check = install_secrets::check(repo);
    if check.ok {
        println!("ok: secrets - {}", check.detail);
        Ok(0)
    } else {
        println!("fail: secrets - {}", check.detail);
        Ok(1)
    }
}

fn ssh_check_dispatch(remote: &str) -> Result<u8> {
    let check = install_ssh::check_key_auth(remote);
    if check.ok {
        println!("ok: ssh - {}", check.detail);
        Ok(0)
    } else {
        println!("fail: ssh - {}", check.detail);
        Ok(1)
    }
}

fn sops_rule_dispatch(repo: &Path, file: &Path) -> Result<u8> {
    let config = sops_config::SopsConfig::load(repo)?;
    let matched = config.match_file(repo, file)?;
    println!("sops rule: {}", matched.path_regex);
    println!("age recipients:");
    for recipient in matched.recipients {
        println!("  {recipient}");
    }
    Ok(0)
}

fn sops_info_dispatch(
    file: &Path,
    show_stanzas: bool,
    match_yubikey: bool,
    unwrap_check: bool,
    unwrap_file_key: bool,
    unwrap_data_key: bool,
    check_values: bool,
) -> Result<u8> {
    let metadata = sops_metadata::SopsMetadata::load(file)?;
    let show_stanzas =
        show_stanzas || unwrap_check || unwrap_file_key || unwrap_data_key || check_values;
    let unwrap_check = unwrap_check || unwrap_file_key || unwrap_data_key || check_values;
    let match_yubikey =
        match_yubikey || unwrap_check || unwrap_file_key || unwrap_data_key || check_values;
    let yubikey_recipients = match match_yubikey {
        true => Some(yubikey_probe::recipients()?),
        false => None,
    };
    println!("sops file: {}", file.display());
    println!("age recipients:");
    for recipient in metadata.recipients() {
        println!("  {recipient}");
    }
    if show_stanzas {
        println!("age stanzas:");
        for entry in metadata.entries() {
            println!("  recipient: {}", entry.recipient);
            let mut connected = false;
            if let Some(report) = yubikey_recipients.as_ref() {
                if let Some(info) = report.find_recipient(&entry.recipient) {
                    connected = true;
                    println!(
                        "    connected=true yubikey_serial={} slot={}",
                        info.serial, info.slot
                    );
                } else {
                    println!("    connected=false");
                }
            }
            for stanza in &entry.stanzas {
                let backend = if stanza.is_yubikey() {
                    "yubikey"
                } else {
                    "software"
                };
                println!(
                    "    {} args={} body={} backend={}",
                    stanza.stanza_type,
                    stanza.args.len(),
                    stanza.body_len,
                    backend
                );
                if unwrap_check && stanza.is_yubikey() {
                    let check = stanza.unwrap_check();
                    let ok = connected && check.ok;
                    let reason = if connected {
                        check.reason
                    } else {
                        "matching YubiKey is not connected".to_string()
                    };
                    println!("      unwrap_check={} reason={}", ok, reason);
                }
            }
            if unwrap_file_key
                && connected
                && entry.stanzas.iter().any(|stanza| stanza.is_yubikey())
            {
                let Some(report) = yubikey_recipients.as_ref() else {
                    continue;
                };
                let Some(info) = report.find_recipient(&entry.recipient) else {
                    continue;
                };
                let unwrapped = sops_unwrap::unwrap_entry(entry, info)?;
                println!("    file_key_sha256_128={}", unwrapped.fingerprint);
            }
        }
    }
    if unwrap_data_key || check_values {
        let Some(report) = yubikey_recipients.as_ref() else {
            return Err("YubiKey recipient report was not loaded".to_string());
        };
        let data_key = sops_data_key::decrypt_first(&metadata, report)?;
        if unwrap_data_key {
            println!(
                "data_key: ok bytes={} sha256_128={}",
                data_key.len(),
                data_key.fingerprint()
            );
        }
        if check_values {
            let report = sops_values::check_file(file, &data_key)?;
            println!(
                "values: ok decrypted={}/{} mac_decrypted={} mac_matches={}",
                report.decrypted_values,
                report.encrypted_values,
                report.mac_decrypted,
                report.mac_matches
            );
        }
    }
    Ok(0)
}

fn yubikey_dispatch(command: YubikeyCommand) -> Result<u8> {
    match command {
        YubikeyCommand::Status => {
            let report = yubikey_probe::status()?;
            if report.has_reader() {
                println!("YubiKey readers:");
                for reader in report.readers {
                    if let Some(yubikey) = reader.yubikey {
                        println!(
                            "  {}: YubiKey serial {} version {}",
                            reader.name, yubikey.serial, yubikey.version
                        );
                    } else {
                        println!("  {}: no YubiKey opened", reader.name);
                    }
                }
            } else {
                println!("YubiKey readers: none");
            }
            Ok(0)
        }
        YubikeyCommand::Recipients => {
            let report = yubikey_probe::recipients()?;
            if report.recipients.is_empty() {
                println!("YubiKey recipients: none");
                return Ok(1);
            }

            println!("YubiKey recipients:");
            for recipient in report.recipients {
                println!("  serial {} slot {}", recipient.serial, recipient.slot);
                println!("    age1tag: {}", recipient.tag_recipient);
                println!("    age1yubikey: {}", recipient.yubikey_recipient);
            }
            Ok(0)
        }
    }
}
