"""dump's manager: follows the target list kept by the hub and reaches every disk target
over SSH, where only `dump-target` and btrbk's filtered commands run.

`manager.py sync` (every few minutes): per disk target, list the machine's disks (so a
disk can be picked on the status page), format the one picked once its serial was typed
to confirm and it is blank, keep it mounted, write its btrbk config; then report every
target's state and copies to the hub. `manager.py push` (nightly): send the newest
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

sys.path.insert(0, str(Path(__file__).parent))
from fields import valid  # noqa: E402

HUB = os.environ["DUMP_HUB"]
HOME = Path(os.environ.get("DUMP_HOME", "/var/lib/dump/manager"))
SOURCE = json.loads(os.environ["DUMP_SOURCE"])
KEY = HOME / "id_ed25519"
KNOWN = HOME / "known_hosts"


def run(*cmd, check=True, **kw):
    return subprocess.run(cmd, check=check, capture_output=True, text=True, **kw)


def write(path, text, mode=0o644):
    new = path.with_name(path.name + ".new")
    new.write_text(text)
    os.chmod(new, mode)
    new.replace(path)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


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


def ssh_config(targets):
    """Only the targets' hosts use the manager's known_hosts, for its SSH and btrbk's."""
    hosts = sorted({t["host"] for t in targets.values() if t.get("kind") == "btrbk"})
    write(HOME / "ssh_config", "".join(f"Host {h}\n  UserKnownHostsFile {KNOWN}\n  StrictHostKeyChecking accept-new\n" for h in hosts))


def target(t, *args, timeout=600):
    """`dump-target ARGS` on the target machine, as its dump user."""
    return subprocess.run(["ssh", "-i", str(KEY), "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                           "-l", t.get("user") or "dump", "--", t["host"], "dump-target", *args],
                          capture_output=True, text=True, timeout=timeout)


# --- the target machine's disks, as the page offers them ----------------------------------

def disks(t):
    result = target(t, "probe", timeout=60)
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


def disk_target(name, t):
    mnt = mount_of(name)
    conf = HOME / f"btrbk-{name}.conf"
    found = disks(t)
    disk = next((d for d in found if t.get("disk") and d["id"] == t["disk"]), None)
    by_id = lambda d: d["id"].rsplit("/", 1)[-1]
    lv = target(t, "lv", name, timeout=60).stdout.strip()

    if t.get("state") == "removed":
        conf.unlink(missing_ok=True)
        target(t, "umount", name)
        if t.get("wipe") and lv and disk and t["wipe"] == disk["serial"]:
            wiped = target(t, "wipe", name, by_id(disk), disk["serial"])
            if wiped.returncode:
                return {"state": "error", "detail": f"wiping failed: {wiped.stderr.strip()[-300:]}"}
            return {"state": "wiped"}
        return {"state": "removed", "detail": "its copies stay on the disk"}

    if not lv:
        if not t.get("disk"):
            return {"state": "pick-disk", "disks": found, "detail": "pick the disk to use"}
        if not disk:
            return {"state": "error", "disks": found, "detail": f"{t['disk']} is not attached"}
        if not t.get("confirm") or t["confirm"] != disk["serial"] or t.get("serial") != disk["serial"]:
            return {"state": "pick-disk", "disks": found, "detail": "type the disk's serial to confirm"}
        made = target(t, "format", name, by_id(disk), disk["serial"])
        if made.returncode:
            return {"state": "error", "disks": found, "detail": f"not formatted: {made.stderr.strip()[-300:]}"}
        lv = f"/dev/dump-{name}/{name}"

    mounted = target(t, "mount", name)
    if mounted.returncode:
        return {"state": "error", "detail": f"could not mount: {mounted.stderr.strip()[-300:]}"}
    write(conf, "\n".join([
        "timestamp_format long", f"ssh_identity {KEY}", f"ssh_user {t.get('user') or 'dump'}",
        "backend_local btrfs-progs", "backend_remote btrfs-progs-sudo",
        "snapshot_create no", "snapshot_preserve_min all", "target_preserve_min no",
        # A day's copy is its first snapshot from 05:00 UTC, after every service's nightly copy.
        "preserve_hour_of_day 5",
        f"target_preserve {t.get('keep') or '14d 8w 12m'}",
        f"volume {SOURCE['volume']}", f"  snapshot_dir {SOURCE['snapshotDir']}",
        f"  target ssh://{t['host']}{mnt}/nest"] + [f"  subvolume {s}" for s in SOURCE["shares"]]) + "\n")
    return {"state": "ready", "device": lv, "mount": mnt}


def disk_report(name, t):
    mnt = mount_of(name)
    lines = target(t, "report", name, timeout=60).stdout.split("\n") + [""] * 4
    sizes = lines[1].split()
    report = {"at": int(time.time()), "host": t["host"], "mounted": lines[0] == "mounted",
              "copies": lines[2].split(), "push": read_json(HOME / f"push-{name}.json")}
    if len(sizes) == 3 and all(s.isdigit() for s in sizes):
        report["disk"] = {"target": mnt, "size": int(sizes[0]), "used": int(sizes[1]), "avail": int(sizes[2])}
    if lines[3].strip().isdigit():
        report["btrfs_errors"] = int(lines[3])
    return report


# --- restic targets, from this machine itself ---------------------------------------------

def restic_target(name, t):
    password = HOME / f"restic-{name}.pass"
    if t.get("state") == "removed":
        (HOME / f"restic-{name}.json").unlink(missing_ok=True)
        return {"state": "removed", "detail": "the repository and its password stay"}
    if not password.exists():
        write(password, secrets.token_urlsafe(32), 0o600)
    write(HOME / f"restic-{name}.json", json.dumps({"repository": t["repository"], "keep": t.get("keep") or "7d 4w 12m"}))
    return {"state": "ready", "detail": f"its password is in {password}; keep a copy in gopass"}


# --- the commands -------------------------------------------------------------------------

def sync():
    targets = {n: t for n, t in hub("/config")["targets"].items() if not valid(n, t)}
    key = ensure_key()
    ssh_config(targets)
    states = {}
    for name, t in targets.items():
        try:
            states[name] = disk_target(name, t) if t["kind"] == "btrbk" else restic_target(name, t)
        except (RuntimeError, subprocess.SubprocessError, OSError, ValueError) as err:
            states[name] = {"state": "error", "detail": str(err)[:300]}
        states[name]["at"] = int(time.time())
    hub("/agent", {"key": key, "targets": states})
    for name, t in targets.items():
        try:
            if t["kind"] == "btrbk" and states[name]["state"] == "ready":
                hub(f"/report/{name}", disk_report(name, t))
            elif t["kind"] == "restic" and t.get("state") != "removed":
                hub(f"/report/{name}", {"at": int(time.time()), "restic": read_json(HOME / f"restic-{name}-last.json")})
        except (subprocess.SubprocessError, OSError, ValueError) as err:
            print(f"{name}: no report: {err}", file=sys.stderr)


def push():
    for conf in sorted(HOME.glob("btrbk-*.conf")):
        name = conf.stem.removeprefix("btrbk-")
        result = run("btrbk", "-c", str(conf), "run", check=False)
        write(HOME / f"push-{name}.json", json.dumps({
            "at": int(time.time()), "ok": result.returncode == 0,
            "output": (result.stdout + result.stderr).strip().splitlines()[-15:]}))


def restic():
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
            for share in SOURCE["shares"]:
                snaps = sorted(glob.glob(f"{SOURCE['volume']}/{SOURCE['snapshotDir']}/{share}.*"))
                if snaps:
                    mount = mounts / share
                    mount.mkdir(parents=True, exist_ok=True)
                    run("umount", str(mount), check=False)
                    run("mount", "--bind", "-o", "ro", snaps[-1], str(mount))
                    paths.append(str(mount))
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
            for share in SOURCE["shares"]:
                run("umount", str(mounts / share), check=False)
        write(HOME / f"restic-{name}-last.json", json.dumps({"at": int(time.time()), "ok": ok, "output": output}))


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "sync"
    commands = {"sync": sync, "push": push, "restic": restic}
    if command not in commands:
        sys.exit(f"usage: {sys.argv[0]} sync|push|restic")
    commands[command]()
