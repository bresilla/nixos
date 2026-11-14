"""What the mirror service and its settings page share: paths, files and SSH URLs."""
import hashlib
import json
import os
import re
import sqlite3
import tempfile
import urllib.parse

CONFIG = os.environ.get("MIRROR_CONFIG", "/var/lib/git-mirror-config")
STATE = os.environ.get("MIRROR_STATE", "/var/lib/git-mirror")
DATABASE = os.environ["DATABASE"]
MODES = ("push", "pull", "two-way")
NAME = re.compile(r"[A-Za-z0-9._-]{1,100}")
# Only SSH, so the key decides; names start with a letter or digit, so nothing
# reads as an option to ssh or git.
SCP = re.compile(r"(?P<user>[A-Za-z0-9._-]+)@(?P<host>[A-Za-z0-9][A-Za-z0-9.-]*):(?P<path>[A-Za-z0-9._~][A-Za-z0-9._~/-]*)")
SSH = re.compile(r"ssh://(?P<user>[A-Za-z0-9._-]+)@(?P<host>[A-Za-z0-9][A-Za-z0-9.-]*)(?::(?P<port>[0-9]{1,5}))?/(?P<path>[A-Za-z0-9._~][A-Za-z0-9._~/-]*)")


def parse_ssh(url):
    """(user, host, port, path) of an SSH URL, None for anything else."""
    if not isinstance(url, str) or len(url) > 300:
        return None
    m = SSH.fullmatch(url) or SCP.fullmatch(url)
    if not m:
        return None
    path = m["path"].strip("/")
    if not path or any(p in ("", ".", "..") for p in path.split("/")):
        return None
    port = int(m.groupdict().get("port") or 22)
    if not 0 < port < 65536:
        return None
    return m["user"], m["host"].lower(), port, path


def host_key_name(host, port):
    return host if port == 22 else f"[{host}]:{port}"


def namespace_ok(namespace):
    return parse_ssh(f"{namespace}/x") is not None and not namespace.endswith("/")


def where(url):
    """(host, path without .git) of any clone URL gitea may have been given."""
    if not url:
        return None
    ssh = parse_ssh(url)
    if ssh:
        host, path = ssh[1], ssh[3]
    else:
        u = urllib.parse.urlsplit(url)
        if u.scheme not in ("http", "https", "git", "ssh") or not u.hostname:
            return None
        host, path = u.hostname.lower(), u.path.strip("/")
    return host, path.removesuffix(".git").strip("/")


def link_id(url):
    return hashlib.sha256(url.encode()).hexdigest()[:16]


def target_for(namespace, name):
    return f"{namespace}/{name}.git"


def read_json(path, fallback):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, NotADirectoryError, json.JSONDecodeError):
        return fallback


def write_json(path, data, mode=0o664):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def db():
    return sqlite3.connect(f"file:{DATABASE}?mode=ro", uri=True, timeout=5)


# Status 0 is a usable repository; owner visibility 0 is public.
REPO_COLUMNS = ("r.id, lower(r.owner_name), r.lower_name, r.name, r.is_private, r.is_mirror, "
                "r.is_empty, r.is_archived, coalesce(r.original_url, ''), r.created_unix, r.status, "
                "coalesce(r.default_branch, ''), u.visibility, u.type")
REPO_KEYS = ("id", "owner", "lower", "name", "private", "mirror", "empty", "archived",
             "original", "created", "status", "branch", "visibility", "kind")


def repo_rows(where_sql="", args=()):
    with db() as conn:
        rows = conn.execute(f"select {REPO_COLUMNS} from repository r join user u on u.id = r.owner_id {where_sql}", args).fetchall()
    return [dict(zip(REPO_KEYS, row)) for row in rows]


def repo_by_name(owner, repo):
    rows = repo_rows("where lower(r.owner_name) = ? and r.lower_name = ?", (owner.lower(), repo.lower()))
    return rows[0] if rows else None


def blocked(repo):
    """Why a repository may not be mirrored at all; mirrors carry only public code."""
    reasons = []
    if repo["private"]:
        reasons.append("the repository is private")
    if repo["visibility"] != 0:
        reasons.append("its owner is not public")
    return reasons


def mode_blocked(repo, mode):
    """Why gitea cannot take changes in, for the modes that write to it."""
    if mode == "push":
        return None
    if repo["mirror"]:
        return "gitea mirrors this repository itself, so only push works"
    if repo["archived"]:
        return "the repository is archived, so only push works"
    return None


def links_of(repo_id):
    return read_json(f"{CONFIG}/links/{repo_id}.json", {}).get("links", [])


def namespace_of(owner):
    return read_json(f"{CONFIG}/owners/{owner.lower()}.json", {}).get("namespace")


def pinned_hosts(path):
    """Host names a known_hosts file names, as ssh writes them."""
    names = set()
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    names.update(line.split()[0].split(","))
    except FileNotFoundError:
        pass
    return names
