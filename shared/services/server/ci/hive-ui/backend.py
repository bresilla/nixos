"""Muros API and persistent URL identities for the Hive frontend."""
import contextlib
import http.client
import json
import os
import sqlite3
import threading
from datetime import datetime, timezone
from urllib.parse import quote, unquote, urlsplit, urlencode

VIEW = threading.local()
MUTATION = threading.RLock()
ORIGIN = os.environ.get("CI_ORIGIN", "https://build.bresilla.com")
ENDPOINT = urlsplit(os.environ.get("CI_API", "http://127.0.0.1:8090"))
STATE = os.environ.get("CI_UI_STATE", "/var/lib/muros-ui")
DATABASE = os.environ.get("CI_DATABASE", "/var/lib/murosd/server.db")


def connect():
    db = sqlite3.connect(os.path.join(STATE, "frontend.db"), timeout=30)
    db.row_factory = sqlite3.Row
    return db


def initialize():
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    with contextlib.closing(connect()) as db, db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS numbers (
                repo TEXT NOT NULL, run TEXT NOT NULL UNIQUE, number INTEGER NOT NULL,
                UNIQUE(repo, number));
            CREATE TABLE IF NOT EXISTS systems (name TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS drafts (
                name TEXT PRIMARY KEY, address TEXT NOT NULL, enabled INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS snapshots (run TEXT PRIMARY KEY, detail TEXT NOT NULL);
        """)


def request(method, path, body=None, headers=None, raw=False):
    connection = http.client.HTTPConnection(ENDPOINT.hostname, ENDPOINT.port, timeout=35)
    fields = {"Host": urlsplit(ORIGIN).netloc, "Accept": "application/json"}
    fields.update(headers or {})
    if body is not None and not isinstance(body, str):
        body = json.dumps(body)
        fields["Content-Type"] = "application/json"
    try:
        connection.request(method, path, body=body, headers=fields)
        response = connection.getresponse()
        data = response.read()
        if response.status >= 400:
            raise RuntimeError(f"Muros answered {response.status} for {path}")
        return (data.decode(errors="replace") if raw else json.loads(data) if data else None,
                dict(response.getheaders()))
    finally:
        connection.close()


@contextlib.contextmanager
def session(user):
    headers = {"X-Forwarded-Preferred-Username": user, "X-Forwarded-Groups": "admin"}
    identity, response = request("GET", "/auth/me", headers=headers)
    cookie = next((value for key, value in response.items() if key.lower() == "set-cookie"), "")
    if not identity.get("admin") or not cookie or not identity.get("csrf"):
        raise RuntimeError("Muros did not authorize the signed-in administrator")
    headers.update({"Cookie": cookie.split(";", 1)[0], "Origin": ORIGIN,
                    "x-csrf-token": identity["csrf"]})
    try:
        yield headers
    finally:
        request("POST", "/auth/logout", urlencode({"csrf": identity["csrf"]}),
                {**headers, "Content-Type": "application/x-www-form-urlencoded"}, raw=True)


def api(method, path, body=None, raw=False):
    if method == "GET":
        return request(method, path, body, raw=raw)[0]
    user = getattr(VIEW, "user", None)
    if not user:
        raise RuntimeError("administrator required")
    with session(user) as headers:
        return request(method, path, body, headers, raw=raw)[0]


def repository(owner, name):
    return "/api/v1/repos/" + quote(owner, safe="") + "/" + quote(name, safe="")


def iso(value):
    return datetime.fromtimestamp(value / 1000, timezone.utc).isoformat() if value is not None else None


def index(repo):
    uri = "file:" + quote(DATABASE, safe="/") + "?mode=ro"
    with contextlib.closing(sqlite3.connect(uri, uri=True, timeout=30)) as source:
        runs = source.execute("SELECT id FROM run WHERE repo_id=? ORDER BY created_at, id", (repo["id"],)).fetchall()
    key = repo["owner"] + "/" + repo["name"]
    with contextlib.closing(connect()) as db, db:
        db.execute("BEGIN IMMEDIATE")
        number = db.execute("SELECT COALESCE(MAX(number),0) FROM numbers WHERE repo=?", (key,)).fetchone()[0]
        for (run,) in runs:
            if not db.execute("SELECT 1 FROM numbers WHERE run=?", (run,)).fetchone():
                number += 1
                db.execute("INSERT INTO numbers VALUES (?,?,?)", (key, run, number))
        return {row["run"]: row["number"] for row in db.execute("SELECT * FROM numbers WHERE repo=?", (key,))}


def run_id(repo, number):
    for run, assigned in index(repo).items():
        if assigned == int(number):
            return run
    raise ValueError("no such build")


def run_view(run, number):
    result = {**run, "number": number, "commit_sha": run["commit"], "pr_number": None}
    for field in ("created_at", "started_at", "finished_at"):
        result[field] = iso(run[field])
    return result


def snapshot(run):
    with contextlib.closing(connect()) as db:
        row = db.execute("SELECT detail FROM snapshots WHERE run=?", (run,)).fetchone()
        return json.loads(row[0]) if row else None


def jobs(run):
    return api("GET", f"/api/v1/runs/{quote(run, safe='')}/jobs")


def job_view(job):
    return {**job, "status": "succeeded" if job["status"] == "cached" else job["status"],
            "cached": job["status"] == "cached", "started_at": iso(job["started_at"]),
            "finished_at": iso(job["finished_at"])}


def legacy(method, path, user=None, raw=False):
    parts = [unquote(p) for p in urlsplit(path).path.strip("/").split("/")]
    if parts == ["api", "repos"]:
        return [{**repo, "forge": "pull_based", "private": False} for repo in api("GET", "/api/v1/repos")]
    if parts[0] == "api":
        parts = parts[1:]
    if len(parts) < 4 or parts[0] != "repos" or parts[1] != "pull_based":
        raise ValueError("unknown repository route")
    base = repository(parts[2], parts[3])
    repo = api("GET", base)
    rest = parts[4:]
    if not rest:
        return repo
    if rest in (["enable"], ["disable"]):
        return api("PATCH", base, {"enabled": rest == ["enable"]})
    if rest == ["builds"]:
        numbers = index(repo)
        items = []
        for run in api("GET", base + "/runs"):
            archived = snapshot(run["id"])
            items.append(archived["build"] if archived else run_view(run, numbers[run["id"]]))
        return {"items": sorted(items, key=lambda item: datetime.fromisoformat(
            item["created_at"].replace("Z", "+00:00")).timestamp(), reverse=True)}
    if len(rest) < 2 or rest[0] != "builds":
        raise ValueError("unknown build route")
    run = run_id(repo, rest[1])
    archived = snapshot(run)
    target = "/api/v1/runs/" + quote(run, safe="")
    if len(rest) == 2:
        if archived:
            return archived
        attributes = jobs(run)
        build = run_view(api("GET", target), int(rest[1]))
        warnings = {}
        for job in attributes:
            for warning in job.get("warnings", []):
                if isinstance(warning, dict):
                    key = (warning.get("level", "warning"), warning.get("message", str(warning)))
                else:
                    key = ("warning", str(warning))
                warnings[key] = warnings.get(key, 0) + 1
        build["eval_warnings"] = build["config"].get("legacy_eval_warnings", [
            {"level": level, "message": message, "count": count}
            for (level, message), count in warnings.items()])
        mapped = [job_view(job) for job in attributes]
        legacy = build["config"].get("legacy_attributes", {})
        for job in mapped:
            if job["attr"] in legacy:
                job.update(legacy[job["attr"]])
        return {"build": build, "attributes": mapped}
    if rest[2:] in (["restart"], ["cancel"]):
        result = api("POST", target + "/" + rest[2])
        if archived:
            with contextlib.closing(connect()) as db, db:
                db.execute("DELETE FROM snapshots WHERE run=?", (run,))
        return result
    attr = "/".join(rest[4:]) if rest[2:4] == ["logs", "raw"] else "/".join(rest[3:-1])
    if archived and rest[2:4] == ["logs", "raw"]:
        log = archived["logs"].get(attr)
        if not log or not os.path.isfile(log):
            raise RuntimeError("no archived log")
        with open(log, errors="replace") as stream:
            from collections import deque
            return "".join(deque(stream, maxlen=2000))
    job = next((job for job in jobs(run) if job["attr"] == attr), None)
    if not job:
        raise ValueError("no such attribute")
    target = "/api/v1/jobs/" + quote(job["id"], safe="")
    if rest[2:4] == ["logs", "raw"]:
        return "\n".join(api("GET", target + "/log", raw=True).splitlines()[-2000:])
    if rest[2] == "attrs" and rest[-1] == "restart":
        result = api("POST", target + "/restart")
        if archived:
            with contextlib.closing(connect()) as db, db:
                db.execute("DELETE FROM snapshots WHERE run=?", (run,))
        return result
    raise ValueError("unknown attribute route")


def load():
    machines = api("GET", "/api/v1/builders")
    maps = api("GET", "/api/v1/systems")
    with contextlib.closing(connect()) as db, db:
        db.executemany("INSERT OR IGNORE INTO systems VALUES (?)", [(row["system"],) for row in maps])
        systems = {row[0]: "" for row in db.execute("SELECT name FROM systems")}
        drafts = {row["name"]: row for row in db.execute("SELECT * FROM drafts")}
    systems.update({row["system"]: row["builder_name"] for row in maps})
    result = {}
    for machine in machines:
        draft = drafts.get(machine["name"])
        enabled = machine["enabled"]
        if not machine["host_key"] and draft and draft["address"] == machine["address"]:
            enabled = bool(draft["enabled"])
        result[machine["name"]] = {**machine, "features": ",".join(machine["features"]),
                                   "hostKey": machine["host_key"], "enabled": enabled}
    return {"machines": result, "systems": systems}


def save(state):
    current = load()
    for name in current["machines"].keys() - state["machines"].keys():
        api("DELETE", "/api/v1/builders/" + quote(name, safe=""))
    for name, machine in state["machines"].items():
        mapped = sorted(system for system, on in state["systems"].items() if on == name)
        before = current["machines"].get(name)
        old_maps = sorted(system for system, on in current["systems"].items() if on == name)
        fields = ("address", "user", "jobs", "speed", "features", "enabled", "hostKey")
        if before and mapped == old_maps and all(machine[key] == before[key] for key in fields):
            continue
        api("POST", "/api/v1/builders", {
            "name": name, "address": machine["address"], "user": machine["user"],
            "jobs": machine["jobs"], "speed": machine["speed"],
            "features": [word for word in machine["features"].split(",") if word],
            "enabled": bool(machine["enabled"] and machine["hostKey"]),
            "host_key": machine["hostKey"], "systems": mapped,
        })
        with contextlib.closing(connect()) as db, db:
            if not machine["hostKey"]:
                db.execute("INSERT OR REPLACE INTO drafts VALUES (?,?,?)", (name, machine["address"], machine["enabled"]))
            else:
                db.execute("DELETE FROM drafts WHERE name=?", (name,))
    with contextlib.closing(connect()) as db, db:
        db.executemany("INSERT OR IGNORE INTO systems VALUES (?)", [(system,) for system in state["systems"]])
        for name in current["machines"].keys() - state["machines"].keys():
            db.execute("DELETE FROM drafts WHERE name=?", (name,))


def load_repos():
    return {repo["owner"] + "/" + repo["name"]: repo for repo in api("GET", "/api/v1/repos")}


def save_repos(repos):
    current = load_repos()
    for key in current.keys() - repos.keys():
        api("DELETE", repository(*key.split("/")))
    for key in repos.keys() - current.keys():
        repo = repos[key]
        owner, name = key.split("/")
        api("POST", "/api/v1/repos", {"owner": owner, "name": name, "url": repo["url"],
                                      "default_branch": repo["default_branch"],
                                      "poll_interval": repo["poll_interval"]})
