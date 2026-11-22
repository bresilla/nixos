"""The shape a target in targets.json must have; the hub and the manager both check it,
since the file is written by the status page in another container."""

import re

NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,30}")
KEEP = re.compile(r"(\d{1,4}[hdwmy])( \d{1,4}[hdwmy]){0,5}")
HOST = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}")
USER = re.compile(r"[a-z_][a-z0-9_-]{0,31}")
REPOSITORY = re.compile(r"[A-Za-z0-9][A-Za-z0-9:/._@+-]{0,250}")
DISK = re.compile(r"/dev/disk/by-id/[A-Za-z0-9._:-]+")
SERIAL = re.compile(r"[A-Za-z0-9._:-]{1,80}")
STATES = ("active", "removed")


def valid(name, t):
    """None when the target is fine, else what is wrong with it."""
    if not NAME.fullmatch(name or ""):
        return "bad name"
    if not isinstance(t, dict) or t.get("state", "active") not in STATES:
        return "bad entry"
    if t.get("keep") and not KEEP.fullmatch(t["keep"]):
        return "bad keep"
    if t.get("kind") == "restic":
        return None if REPOSITORY.fullmatch(t.get("repository") or "") else "bad repository"
    if t.get("kind") != "btrbk":
        return "bad kind"
    if not HOST.fullmatch(t.get("host") or "") or not USER.fullmatch(t.get("user") or "dump"):
        return "bad host or user"
    if t.get("disk") and not DISK.fullmatch(t["disk"]):
        return "bad disk"
    for field in ("serial", "confirm", "wipe"):
        if t.get(field) and not SERIAL.fullmatch(t[field]):
            return f"bad {field}"
    return None
