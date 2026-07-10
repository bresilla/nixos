//! Target introspection: one structured report describing everything the
//! installer (and later the TUI) needs to know about a machine — hardware,
//! firmware, disks with their current contents, LVM state, mounts, tools.
//!
//! `collect()` always runs on the machine being described: the agent handles
//! `AgentRequest::Facts` by calling it, and a local install calls it directly.
//! Every field is best-effort — a missing tool or unreadable file degrades to
//! `None`/empty instead of failing, so facts collection never blocks an install.

use std::fs;
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TargetFacts {
    pub hostname: Option<String>,
    pub kernel: Option<String>,
    pub os_name: Option<String>,
    pub nixos_version: Option<String>,
    pub arch: Option<String>,
    pub virtualization: Option<String>,
    pub efi: bool,
    pub mem_mib: Option<u64>,
    pub cpu_count: Option<u32>,
    pub cpu_model: Option<String>,
    /// Booted from an installer ISO (live system, safe to wipe disks).
    pub live_iso: bool,
    /// Something is mounted at /mnt (a previous install attempt or manual mount).
    pub mnt_mounted: bool,
    pub disks: Vec<DiskFacts>,
    pub volume_groups: Vec<VgFacts>,
    pub logical_volumes: Vec<LvFacts>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiskFacts {
    pub path: String,
    pub size_bytes: u64,
    pub model: Option<String>,
    pub serial: Option<String>,
    pub transport: Option<String>,
    pub rotational: Option<bool>,
    pub partitions: Vec<PartitionFacts>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PartitionFacts {
    pub path: String,
    pub size_bytes: u64,
    pub fstype: Option<String>,
    pub label: Option<String>,
    pub mountpoints: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct VgFacts {
    pub name: String,
    pub size_bytes: u64,
    pub free_bytes: u64,
    pub pv_count: u32,
    pub lv_count: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LvFacts {
    pub name: String,
    pub vg_name: String,
    pub size_bytes: u64,
    pub active: bool,
}

impl TargetFacts {
    pub fn summary_lines(&self) -> Vec<String> {
        let mut lines = Vec::new();
        lines.push(format!(
            "host: {}  os: {}  kernel: {}",
            self.hostname.as_deref().unwrap_or("?"),
            self.nixos_version
                .as_deref()
                .or(self.os_name.as_deref())
                .unwrap_or("?"),
            self.kernel.as_deref().unwrap_or("?"),
        ));
        lines.push(format!(
            "arch: {}  firmware: {}  virt: {}  live-iso: {}  /mnt mounted: {}",
            self.arch.as_deref().unwrap_or("?"),
            if self.efi { "UEFI" } else { "BIOS" },
            self.virtualization.as_deref().unwrap_or("none"),
            yes_no(self.live_iso),
            yes_no(self.mnt_mounted),
        ));
        lines.push(format!(
            "cpu: {} x {}  memory: {} MiB",
            self.cpu_count.unwrap_or(0),
            self.cpu_model.as_deref().unwrap_or("?"),
            self.mem_mib.unwrap_or(0),
        ));
        for disk in &self.disks {
            let mut line = format!(
                "disk {}  {}  {}",
                disk.path,
                format_bytes(disk.size_bytes),
                disk.model.as_deref().unwrap_or(""),
            );
            if let Some(transport) = &disk.transport {
                line.push_str(&format!("  [{transport}]"));
            }
            lines.push(line.trim_end().to_string());
            for part in &disk.partitions {
                lines.push(format!(
                    "  {}  {}  {}{}{}",
                    part.path,
                    format_bytes(part.size_bytes),
                    part.fstype.as_deref().unwrap_or("-"),
                    part.label
                        .as_deref()
                        .map(|label| format!("  label={label}"))
                        .unwrap_or_default(),
                    if part.mountpoints.is_empty() {
                        String::new()
                    } else {
                        format!("  mounted: {}", part.mountpoints.join(", "))
                    },
                ));
            }
        }
        for vg in &self.volume_groups {
            lines.push(format!(
                "vg {}  {} total, {} free, {} PVs, {} LVs",
                vg.name,
                format_bytes(vg.size_bytes),
                format_bytes(vg.free_bytes),
                vg.pv_count,
                vg.lv_count,
            ));
        }
        for lv in &self.logical_volumes {
            lines.push(format!(
                "lv {}/{}  {}  {}",
                lv.vg_name,
                lv.name,
                format_bytes(lv.size_bytes),
                if lv.active { "active" } else { "inactive" },
            ));
        }
        lines
    }
}

impl DiskFacts {
    /// Short description of what currently lives on this disk, so the disk
    /// picker can show "what am I about to wipe" without extra lookups.
    pub fn content_summary(&self) -> String {
        if self.partitions.is_empty() {
            return "empty".to_string();
        }
        self.partitions
            .iter()
            .map(|part| {
                let mut piece = part.fstype.clone().unwrap_or_else(|| "?".to_string());
                if let Some(label) = &part.label {
                    piece.push_str(&format!("({label})"));
                }
                piece
            })
            .collect::<Vec<_>>()
            .join(", ")
    }
}

/// Convert introspected disks into the wizard's disk choices, preserving the
/// richer facts for display.
pub fn disk_choices(facts: &TargetFacts) -> Vec<crate::install::state::DiskChoice> {
    facts
        .disks
        .iter()
        .map(|disk| crate::install::state::DiskChoice {
            path: disk.path.clone(),
            size_gib: disk.size_bytes.div_ceil(1024 * 1024 * 1024),
            model: disk.model.clone(),
        })
        .collect()
}

/// Gather every fact about the machine this code runs on.
pub fn collect() -> TargetFacts {
    let mut facts = TargetFacts {
        hostname: read_trimmed("/proc/sys/kernel/hostname"),
        kernel: read_trimmed("/proc/sys/kernel/osrelease"),
        arch: command_line("uname", &["-m"]),
        virtualization: detect_virtualization(),
        efi: Path::new("/sys/firmware/efi").exists(),
        live_iso: Path::new("/iso").exists(),
        mnt_mounted: command_status("findmnt", &["/mnt"]),
        ..TargetFacts::default()
    };

    if let Some(os_release) = read_to_string("/etc/os-release") {
        facts.os_name = parse_os_release(&os_release, "PRETTY_NAME");
    }
    facts.nixos_version = command_line("nixos-version", &[]);

    if let Some(meminfo) = read_to_string("/proc/meminfo") {
        facts.mem_mib = parse_mem_total_mib(&meminfo);
    }
    if let Some(cpuinfo) = read_to_string("/proc/cpuinfo") {
        let (count, model) = parse_cpuinfo(&cpuinfo);
        facts.cpu_count = count;
        facts.cpu_model = model;
    }

    if let Some(json) = command_output(
        "lsblk",
        &[
            "--json",
            "--bytes",
            "--output",
            "NAME,PATH,SIZE,TYPE,MODEL,SERIAL,TRAN,ROTA,FSTYPE,LABEL,MOUNTPOINTS",
        ],
    ) {
        facts.disks = parse_lsblk_facts(&json).unwrap_or_default();
    }

    if let Some(json) = command_output(
        "sudo",
        &[
            "--non-interactive",
            "vgs",
            "--reportformat",
            "json",
            "--units",
            "b",
            "--nosuffix",
            "-o",
            "vg_name,vg_size,vg_free,pv_count,lv_count",
        ],
    ) {
        facts.volume_groups = parse_vgs_facts(&json).unwrap_or_default();
    }
    if let Some(json) = command_output(
        "sudo",
        &[
            "--non-interactive",
            "lvs",
            "--reportformat",
            "json",
            "--units",
            "b",
            "--nosuffix",
            "-o",
            "lv_name,vg_name,lv_size,lv_active",
        ],
    ) {
        facts.logical_volumes = parse_lvs_facts(&json).unwrap_or_default();
    }

    facts
}

fn detect_virtualization() -> Option<String> {
    let out = command_line("systemd-detect-virt", &[])?;
    if out == "none" {
        None
    } else {
        Some(out)
    }
}

fn read_to_string(path: &str) -> Option<String> {
    fs::read_to_string(path).ok()
}

fn read_trimmed(path: &str) -> Option<String> {
    read_to_string(path).map(|value| value.trim().to_string())
}

fn command_output(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).to_string())
}

fn command_line(program: &str, args: &[&str]) -> Option<String> {
    let out = command_output(program, args)?;
    let line = out.lines().next()?.trim();
    (!line.is_empty()).then(|| line.to_string())
}

fn command_status(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

pub fn parse_os_release(content: &str, key: &str) -> Option<String> {
    content.lines().find_map(|line| {
        let value = line.strip_prefix(&format!("{key}="))?;
        Some(value.trim().trim_matches('"').to_string())
    })
}

pub fn parse_mem_total_mib(meminfo: &str) -> Option<u64> {
    meminfo.lines().find_map(|line| {
        let rest = line.strip_prefix("MemTotal:")?;
        let kib = rest.trim().trim_end_matches(" kB").trim().parse::<u64>().ok()?;
        Some(kib / 1024)
    })
}

pub fn parse_cpuinfo(cpuinfo: &str) -> (Option<u32>, Option<String>) {
    let count = cpuinfo
        .lines()
        .filter(|line| line.starts_with("processor"))
        .count() as u32;
    let model = cpuinfo.lines().find_map(|line| {
        let (key, value) = line.split_once(':')?;
        (key.trim() == "model name").then(|| value.trim().to_string())
    });
    ((count > 0).then_some(count), model)
}

pub fn parse_lsblk_facts(json: &str) -> Option<Vec<DiskFacts>> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let devices = value.get("blockdevices")?.as_array()?;
    let mut disks = Vec::new();
    for device in devices {
        if device.get("type").and_then(|v| v.as_str()) != Some("disk") {
            continue;
        }
        let Some(path) = string_field(device, "path") else {
            continue;
        };
        let mut disk = DiskFacts {
            path,
            size_bytes: u64_field(device, "size").unwrap_or(0),
            model: string_field(device, "model"),
            serial: string_field(device, "serial"),
            transport: string_field(device, "tran"),
            rotational: device.get("rota").and_then(|v| v.as_bool()),
            partitions: Vec::new(),
        };
        if let Some(children) = device.get("children").and_then(|v| v.as_array()) {
            for child in children {
                let Some(path) = string_field(child, "path") else {
                    continue;
                };
                disk.partitions.push(PartitionFacts {
                    path,
                    size_bytes: u64_field(child, "size").unwrap_or(0),
                    fstype: string_field(child, "fstype"),
                    label: string_field(child, "label"),
                    mountpoints: child
                        .get("mountpoints")
                        .and_then(|v| v.as_array())
                        .map(|values| {
                            values
                                .iter()
                                .filter_map(|v| v.as_str())
                                .map(ToString::to_string)
                                .collect()
                        })
                        .unwrap_or_default(),
                });
            }
        }
        disks.push(disk);
    }
    Some(disks)
}

pub fn parse_vgs_facts(json: &str) -> Option<Vec<VgFacts>> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let rows = lvm_report_rows(&value, "vg")?;
    Some(
        rows.iter()
            .filter_map(|row| {
                Some(VgFacts {
                    name: string_field(row, "vg_name")?,
                    size_bytes: lvm_number(row, "vg_size").unwrap_or(0),
                    free_bytes: lvm_number(row, "vg_free").unwrap_or(0),
                    pv_count: lvm_number(row, "pv_count").unwrap_or(0) as u32,
                    lv_count: lvm_number(row, "lv_count").unwrap_or(0) as u32,
                })
            })
            .collect(),
    )
}

pub fn parse_lvs_facts(json: &str) -> Option<Vec<LvFacts>> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let rows = lvm_report_rows(&value, "lv")?;
    Some(
        rows.iter()
            .filter_map(|row| {
                Some(LvFacts {
                    name: string_field(row, "lv_name")?,
                    vg_name: string_field(row, "vg_name").unwrap_or_default(),
                    size_bytes: lvm_number(row, "lv_size").unwrap_or(0),
                    active: string_field(row, "lv_active")
                        .map(|value| value == "active")
                        .unwrap_or(false),
                })
            })
            .collect(),
    )
}

fn lvm_report_rows<'a>(value: &'a serde_json::Value, key: &str) -> Option<&'a Vec<serde_json::Value>> {
    value
        .get("report")?
        .as_array()?
        .first()?
        .get(key)?
        .as_array()
}

fn string_field(value: &serde_json::Value, key: &str) -> Option<String> {
    let field = value.get(key)?;
    let text = field.as_str()?.trim();
    (!text.is_empty()).then(|| text.to_string())
}

fn u64_field(value: &serde_json::Value, key: &str) -> Option<u64> {
    let field = value.get(key)?;
    field
        .as_u64()
        .or_else(|| field.as_str().and_then(|text| text.trim().parse().ok()))
}

fn lvm_number(value: &serde_json::Value, key: &str) -> Option<u64> {
    let field = value.get(key)?;
    field.as_u64().or_else(|| {
        field
            .as_str()
            .and_then(|text| text.trim().parse::<f64>().ok())
            .map(|number| number as u64)
    })
}

pub fn format_bytes(bytes: u64) -> String {
    const GIB: u64 = 1024 * 1024 * 1024;
    const MIB: u64 = 1024 * 1024;
    if bytes >= GIB {
        format!("{:.1}G", bytes as f64 / GIB as f64)
    } else if bytes >= MIB {
        format!("{}M", bytes / MIB)
    } else {
        format!("{bytes}B")
    }
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_os_release_pretty_name() {
        let content = "NAME=NixOS\nPRETTY_NAME=\"NixOS 26.05 (Yarara)\"\n";
        assert_eq!(
            parse_os_release(content, "PRETTY_NAME").as_deref(),
            Some("NixOS 26.05 (Yarara)")
        );
        assert_eq!(parse_os_release(content, "MISSING"), None);
    }

    #[test]
    fn parses_mem_total() {
        let meminfo = "MemTotal:       16303492 kB\nMemFree:         1234 kB\n";
        assert_eq!(parse_mem_total_mib(meminfo), Some(15921));
    }

    #[test]
    fn parses_cpuinfo_count_and_model() {
        let cpuinfo = "processor\t: 0\nmodel name\t: AMD Ryzen 7\nprocessor\t: 1\nmodel name\t: AMD Ryzen 7\n";
        let (count, model) = parse_cpuinfo(cpuinfo);
        assert_eq!(count, Some(2));
        assert_eq!(model.as_deref(), Some("AMD Ryzen 7"));
    }

    #[test]
    fn parses_lsblk_disks_with_partitions() {
        let json = r#"{
          "blockdevices": [
            {"name":"loop0","path":"/dev/loop0","size":1000,"type":"loop"},
            {"name":"sda","path":"/dev/sda","size":4000000000000,"type":"disk",
             "model":"QEMU HARDDISK","serial":"QM00001","tran":"sata","rota":true,
             "children":[
               {"name":"sda1","path":"/dev/sda1","size":1072693248,"type":"part",
                "fstype":"vfat","label":null,"mountpoints":[null]},
               {"name":"sda2","path":"/dev/sda2","size":3998000000000,"type":"part",
                "fstype":"LVM2_member","label":null,"mountpoints":["/mnt"]}
             ]}
          ]
        }"#;

        let disks = parse_lsblk_facts(json).unwrap();
        assert_eq!(disks.len(), 1);
        let disk = &disks[0];
        assert_eq!(disk.path, "/dev/sda");
        assert_eq!(disk.model.as_deref(), Some("QEMU HARDDISK"));
        assert_eq!(disk.transport.as_deref(), Some("sata"));
        assert_eq!(disk.rotational, Some(true));
        assert_eq!(disk.partitions.len(), 2);
        assert_eq!(disk.partitions[0].fstype.as_deref(), Some("vfat"));
        assert!(disk.partitions[0].mountpoints.is_empty());
        assert_eq!(disk.partitions[1].mountpoints, vec!["/mnt".to_string()]);
    }

    #[test]
    fn parses_vgs_and_lvs_reports() {
        let vgs = r#"{"report":[{"vg":[
          {"vg_name":"pool","vg_size":"3997999300608","vg_free":"3505999300608","pv_count":"1","lv_count":"6"}
        ]}]}"#;
        let lvs = r#"{"report":[{"lv":[
          {"lv_name":"root","vg_name":"pool","lv_size":"34359738368","lv_active":"active"},
          {"lv_name":"swap","vg_name":"pool","lv_size":"68719476736","lv_active":""}
        ]}]}"#;

        let vg = &parse_vgs_facts(vgs).unwrap()[0];
        assert_eq!(vg.name, "pool");
        assert_eq!(vg.pv_count, 1);
        assert_eq!(vg.lv_count, 6);
        assert_eq!(vg.free_bytes, 3505999300608);

        let lvs = parse_lvs_facts(lvs).unwrap();
        assert_eq!(lvs.len(), 2);
        assert!(lvs[0].active);
        assert!(!lvs[1].active);
        assert_eq!(lvs[1].vg_name, "pool");
    }

    #[test]
    fn summary_renders_key_facts() {
        let facts = TargetFacts {
            hostname: Some("nixos".into()),
            nixos_version: Some("26.05".into()),
            kernel: Some("6.18".into()),
            arch: Some("x86_64".into()),
            efi: true,
            live_iso: true,
            mem_mib: Some(15921),
            cpu_count: Some(8),
            cpu_model: Some("AMD".into()),
            disks: vec![DiskFacts {
                path: "/dev/sda".into(),
                size_bytes: 4000000000000,
                model: Some("QEMU".into()),
                ..DiskFacts::default()
            }],
            ..TargetFacts::default()
        };

        let lines = facts.summary_lines().join("\n");
        assert!(lines.contains("host: nixos"));
        assert!(lines.contains("UEFI"));
        assert!(lines.contains("live-iso: yes"));
        assert!(lines.contains("/dev/sda"));
    }
}
