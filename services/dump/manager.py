"""dump's manager, on nest: follows the target list kept on hive and reaches every disk
target over SSH; the target machines run nothing of dump's own.

`manager.py sync` (every few minutes): per disk target, list the machine's disks (so a
disk can be picked on status.bresilla.com), format the one picked once its serial was
typed to confirm and it is blank, keep it mounted, write its btrbk config; then report
every target's state and copies to hive. `manager.py push` (nightly): send nest's newest
snapshots to every ready disk target. `manager.py restic` (nightly): the restic targets.
"""

import glob
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HUB = os.environ["DUMP_HUB"]
HOME = Path(os.environ.get("DUMP_HOME", "/var/lib/dump/manager"))
KEY = HOME / "id_ed25519"
KNOWN = HOME / "known_hosts"
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,30}")


def run(*cmd, check=True, **kw):
    return subprocess.run(cmd, check=check, capture_output=True, text=True, **kw)


def hub(path, data=None):
    body = None if data is None else json.dumps(data).encode()
    request = urllib.request.Request(HUB + path, data=body, method="POST" if body is not None else "GET",
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read() or b"{}")


def ensure_key():
    HOME.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not KEY.exists():
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "dump@nest", "-f", str(KEY))
    return KEY.with_suffix(".pub").read_text().strip()


def ssh_args(t):
    return ["ssh", "-i", str(KEY), "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={KNOWN}",
            f"{t.get('user') or 'dump'}@{t['host']}"]


def remote(t, script, check=False, timeout=600):
    """A small shell script run on the target machine; its commands use sudo -n."""
    return subprocess.run(ssh_args(t) + ["sh", "-s"], input=script, capture_output=True, text=True,
                          check=check, timeout=timeout)


def q(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


# --- the target machine's disks, as the page offers them ----------------------------------

PROBE = r"""
set -e
lsblk -J -b -o NAME,PATH,SIZE,MODEL,SERIAL,TYPE,TRAN,FSTYPE,MOUNTPOINTS
echo '---'
for l in /dev/disk/by-id/*; do case "$l" in *-part[0-9]*|*/wwn-*|*/nvme-eui*|*/lvm-*|*/dm-*) continue;; esac; echo "$l $(readlink -f "$l")"; done
"""


def disks(t):
    result = remote(t, PROBE, timeout=60)
    if result.returncode:
        raise RuntimeError(f"cannot reach {t['host']} over SSH: {result.stderr.strip()[:200]}")
    tree, _, links = result.stdout.partition("---")
    ids = {}
    for line in links.split("\n"):
        if " " in line:
            link, real = line.split(" ", 1)
            ids.setdefault(real.strip(), link)
    out = []
    for d in json.loads(tree).get("blockdevices", []):
        if d.get("type") != "disk" or re.match(r"(loop|zram|mmcblk\d+boot|sr)", d["name"]):
            continue
        blank = not d.get("children") and not d.get("fstype") and not any(d.get("mountpoints") or [])
        out.append({"id": ids.get(d["path"]), "path": d["path"], "size": d.get("size"), "model": (d.get("model") or "").strip(),
                    "serial": (d.get("serial") or "").strip(), "tran": d.get("tran"), "blank": blank})
    return out


# --- a disk target, brought to what the list asks ----------------------------------------

def mount_of(name):
    return f"/mnt/dump/{name}"


def disk_target(name, t, source):
    mnt = mount_of(name)
    conf = HOME / f"btrbk-{name}.conf"
    found = disks(t)
    disk = next((d for d in found if t.get("disk") and d["id"] == t["disk"]), None)
    lv_probe = remote(t, f"ls -d /dev/dump*/{q(name)} 2>/dev/null | head -1").stdout.strip()

    if t.get("state") == "removed":
        conf.unlink(missing_ok=True)
        remote(t, f"sudo -n umount {q(mnt)} 2>/dev/null; true")
        if t.get("wipe") and lv_probe and disk and t["wipe"] == disk["serial"]:
            vg = lv_probe.split("/")[2]
            remote(t, f"sudo -n lvremove -f {q(lv_probe)}; sudo -n vgremove -f {q(vg)}; sudo -n wipefs -a {q(disk['path'])}")
            return {"state": "wiped"}
        return {"state": "removed", "detail": "its copies stay on the disk"}

    if not lv_probe:
        if not t.get("disk"):
            return {"state": "pick-disk", "disks": found, "detail": "pick the disk to use"}
        if not disk:
            return {"state": "error", "disks": found, "detail": f"{t['disk']} is not attached"}
        if not t.get("confirm") or t["confirm"] != disk["serial"] or t.get("serial") != disk["serial"]:
            return {"state": "pick-disk", "disks": found, "detail": "type the disk's serial to confirm"}
        if not disk["blank"] or remote(t, f"sudo -n wipefs -n {q(disk['path'])}").stdout.strip():
            return {"state": "error", "disks": found, "detail": "the disk is not blank; it was not touched"}
        vg = f"dump-{name}"
        made = remote(t, "set -e\n" + "\n".join([
            f"sudo -n pvcreate -ff -y {q(disk['path'])}", f"sudo -n vgcreate {q(vg)} {q(disk['path'])}",
            f"sudo -n lvcreate -y -l 100%FREE -n {q(name)} {q(vg)}", f"sudo -n mkfs.btrfs -L {q('dump-' + name)} /dev/{vg}/{name}"]))
        if made.returncode:
            return {"state": "error", "detail": f"formatting failed: {made.stderr.strip()[-300:]}"}
        lv_probe = f"/dev/{vg}/{name}"

    mounted = remote(t, "\n".join([
        f"sudo -n mkdir -p {q(mnt)}",
        f"mountpoint -q {q(mnt)} || sudo -n mount -o noatime,compress=zstd:3 {q(lv_probe)} {q(mnt)}",
        f"sudo -n mkdir -p {q(mnt + '/nest')}", f"mountpoint -q {q(mnt)}"]))
    if mounted.returncode:
        return {"state": "error", "detail": f"could not mount: {mounted.stderr.strip()[-300:]}"}
    conf.write_text("\n".join([
        "timestamp_format long", f"ssh_identity {KEY}", f"ssh_user {t.get('user') or 'dump'}",
        "backend_local btrfs-progs", "backend_remote btrfs-progs-sudo",
        "snapshot_create no", "snapshot_preserve_min all", "target_preserve_min no",
        # A day's copy is its first snapshot after 06:00, once the services' own nightly copies are in.
        "preserve_hour_of_day 6",
        f"target_preserve {t.get('keep') or '14d 8w 12m'}",
        f"volume {source['volume']}", f"  snapshot_dir {source['snapshotDir']}",
        f"  target ssh://{t['host']}{mnt}/nest"] + [f"  subvolume {s}" for s in source["shares"]]) + "\n")
    return {"state": "ready", "device": lv_probe, "mount": mnt}


REPORT = r"""
m={mnt}
if mountpoint -q "$m"; then echo mounted; else echo unmounted; fi
df -B1 --output=size,used,avail "$m" | tail -1
ls "$m/nest" 2>/dev/null | tr '\n' ' '; echo
sudo -n btrfs device stats "$m" 2>/dev/null | awk '{{s += $2}} END {{print s + 0}}'
"""


def disk_report(name, t):
    mnt = mount_of(name)
    lines = remote(t, REPORT.format(mnt=q(mnt)), timeout=60).stdout.split("\n")
    lines += [""] * 4
    sizes = lines[1].split()
    push = HOME / f"push-{name}.json"
    report = {"at": int(time.time()), "host": t["host"], "mounted": lines[0] == "mounted",
              "backups": {"drive": lines[0] == "mounted", "copies": lines[2].split()},
              "push": json.loads(push.read_text()) if push.exists() else None}
    if len(sizes) == 3 and all(s.isdigit() for s in sizes):
        report["disk"] = {"target": mnt, "size": int(sizes[0]), "used": int(sizes[1]), "avail": int(sizes[2])}
    if lines[3].strip().isdigit():
        report["btrfs_errors"] = int(lines[3])
    return report


# --- restic targets, from nest itself -----------------------------------------------------

def restic_target(name, t):
    password = HOME / f"restic-{name}.pass"
    if t.get("state") == "removed":
        (HOME / f"restic-{name}.json").unlink(missing_ok=True)
        return {"state": "removed", "detail": "the repository and its password stay"}
    if not password.exists():
        password.write_text(secrets.token_urlsafe(32))
        os.chmod(password, 0o600)
    (HOME / f"restic-{name}.json").write_text(json.dumps({"repository": t["repository"], "keep": t.get("keep") or "7d 4w 12m"}))
    return {"state": "ready", "detail": f"its password is in {password} on nest; keep a copy in gopass"}


# --- the commands -------------------------------------------------------------------------

def sync():
    config = hub("/config")
    source = config["source"]
    key = ensure_key()
    states = {}
    for name, t in config["targets"].items():
        if not NAME.fullmatch(name):
            continue
        try:
            states[name] = disk_target(name, t, source) if t.get("kind") == "btrbk" else restic_target(name, t)
        except (RuntimeError, subprocess.SubprocessError, OSError, ValueError) as err:
            states[name] = {"state": "error", "detail": str(err)[:300]}
        states[name]["at"] = int(time.time())
    hub("/agent", {"key": key, "targets": states})
    for name, t in config["targets"].items():
        if t.get("kind") == "btrbk" and states.get(name, {}).get("state") == "ready":
            hub(f"/report/{name}", disk_report(name, t))
        elif t.get("kind") == "restic" and NAME.fullmatch(name) and t.get("state") != "removed":
            last = HOME / f"restic-{name}-last.json"
            hub(f"/report/{name}", {"at": int(time.time()), "restic": json.loads(last.read_text()) if last.exists() else None})


def push():
    for conf in sorted(HOME.glob("btrbk-*.conf")):
        name = conf.stem.removeprefix("btrbk-")
        result = run("btrbk", "-c", str(conf), "run", check=False)
        (HOME / f"push-{name}.json").write_text(json.dumps({
            "at": int(time.time()), "ok": result.returncode == 0,
            "output": (result.stdout + result.stderr).strip().splitlines()[-15:]}))


def restic(source):
    mounts = Path("/run/dump-restic")
    for spec in sorted(HOME.glob("restic-*.json")):
        name = spec.stem.removeprefix("restic-")
        if name.endswith("-last"):
            continue
        cfg = json.loads(spec.read_text())
        env = dict(os.environ, RESTIC_REPOSITORY=cfg["repository"], RESTIC_PASSWORD_FILE=str(HOME / f"restic-{name}.pass"),
                   RCLONE_CONFIG="/var/lib/dump/rclone.conf")
        ok, output = False, []
        try:
            paths = []
            for share in source["shares"]:
                snaps = sorted(glob.glob(f"{source['volume']}/{source['snapshotDir']}/{share}.*"))
                if snaps:
                    target = mounts / share
                    target.mkdir(parents=True, exist_ok=True)
                    run("umount", str(target), check=False)
                    run("mount", "--bind", "-o", "ro", snaps[-1], str(target))
                    paths.append(str(target))
            if run("restic", "cat", "config", check=False, env=env).returncode:
                run("restic", "init", env=env)
            backup = run("restic", "backup", "--host", "nest", *paths, check=False, env=env)
            flags = []
            for k in (cfg.get("keep") or "").split():
                unit = {"h": "hourly", "d": "daily", "w": "weekly", "m": "monthly", "y": "yearly"}.get(k[-1:])
                if unit and k[:-1].isdigit():
                    flags += [f"--keep-{unit}", k[:-1]]
            forget = run("restic", "forget", "--prune", "--host", "nest", *flags, check=False, env=env)
            ok = backup.returncode == 0 and forget.returncode == 0
            output = (backup.stdout + backup.stderr + forget.stderr).strip().splitlines()[-15:]
        except (subprocess.CalledProcessError, OSError) as err:
            output = [str(getattr(err, "stderr", "") or err)[:300]]
        finally:
            for share in source["shares"]:
                run("umount", str(mounts / share), check=False)
        (HOME / f"restic-{name}-last.json").write_text(json.dumps({"at": int(time.time()), "ok": ok, "output": output}))


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "sync"
    if command == "sync":
        sync()
    elif command == "push":
        push()
    elif command == "restic":
        restic(hub("/config")["source"])
    else:
        sys.exit(f"usage: {sys.argv[0]} sync|push|restic")
