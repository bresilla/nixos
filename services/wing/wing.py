"""wing.bresilla.com: projects, and each project's tasks and plans, in the sites' own style.

Projects are registered here (by the wing CLI or on the page); each lists its remotes, and a
remote on git.bresilla.com brings its version, issues and pull requests, build.bresilla.com
its builds. Every task and plan belongs to one project and is numbered within it. They live
in SQLite. Pages sit behind the login proxy, which puts the name in a header; /api answers
the CLI with a token made on the settings page.
"""

import base64
import contextlib
import email.parser
import email.policy
import io
import hashlib
import html
import http.client
import json
import os
import re
import secrets
import sqlite3
import tarfile
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlencode, urlparse, urlsplit

import site_ui

env = os.environ.get
LISTEN = env("WING_LISTEN", "127.0.0.1:8098")
DOMAIN = env("WING_DOMAIN", "wing.bresilla.com")
DATABASE = env("WING_DATABASE", "/var/lib/wing/wing.db")
GITEA = env("WING_GITEA", "https://git.bresilla.com")
MUROS = env("WING_MUROS", "https://build.bresilla.com")
SITE = "wing"
STATES = [("todo", "To do"), ("doing", "Doing"), ("done", "Done")]
STATE_NAMES = dict(STATES)
PRIORITIES = {0: "low", 1: "normal", 2: "high"}
LINKS = [("projects", "/", "Projects"), ("tasks", "/tasks", "Tasks"), ("templates", "/templates", "Templates"),
         ("settings", "/settings", "Settings")]
e = html.escape



# --- Storage. -------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS projects (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, namespace TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '', language TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]',
  remotes TEXT NOT NULL DEFAULT '[]', created TEXT NOT NULL, updated TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS plans (
  id INTEGER PRIMARY KEY, project INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE, number INTEGER NOT NULL,
  title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'open',
  created TEXT NOT NULL, updated TEXT NOT NULL, UNIQUE (project, number));
CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY, project INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE, number INTEGER NOT NULL,
  plan INTEGER REFERENCES plans(id) ON DELETE SET NULL, title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'todo', priority INTEGER NOT NULL DEFAULT 1, due TEXT NOT NULL DEFAULT '',
  created TEXT NOT NULL, updated TEXT NOT NULL, done_at TEXT NOT NULL DEFAULT '', UNIQUE (project, number));
CREATE TABLE IF NOT EXISTS tokens (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, hash TEXT NOT NULL UNIQUE, created TEXT NOT NULL, used TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS templates (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, description TEXT NOT NULL DEFAULT '', created TEXT NOT NULL, updated TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS template_files (
  id INTEGER PRIMARY KEY, template INTEGER NOT NULL REFERENCES templates(id) ON DELETE CASCADE, path TEXT NOT NULL,
  data BLOB NOT NULL, mode INTEGER NOT NULL DEFAULT 420, updated TEXT NOT NULL, UNIQUE (template, path));
"""


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@contextlib.contextmanager
def db():
    connection = sqlite3.connect(DATABASE, timeout=30)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def initialize():
    os.makedirs(os.path.dirname(DATABASE), exist_ok=True)
    with db() as c:
        c.execute("PRAGMA journal_mode = WAL")
        c.executescript(SCHEMA)


def project_view(row):
    p = dict(row)
    p["tags"] = json.loads(p["tags"])
    p["remotes"] = json.loads(p["remotes"])
    p["gitea"] = next((g for g in map(gitea_key, (r["url"] for r in p["remotes"])) if g), None)
    return p


def projects():
    with db() as c:
        return [project_view(r) for r in c.execute("SELECT * FROM projects ORDER BY namespace, name")]


def project(name):
    with db() as c:
        row = c.execute("SELECT * FROM projects WHERE name = ?", (name,)).fetchone()
    return project_view(row) if row else None


def need_project(name):
    p = project(name)
    if not p:
        raise LookupError(f"no project named {name}")
    return p


def clean_remotes(remotes):
    out = []
    for r in remotes or []:
        if isinstance(r, str):
            r = {"name": "origin" if not out else f"remote{len(out)}", "url": r}
        url = str(r.get("url", "")).strip()
        if url:
            out.append({"name": str(r.get("name") or "origin").strip(), "url": url})
    return out


def save_project(data):
    """Create or update a project by name; fields left out keep their value."""
    name = str(data.get("name", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", name):
        raise ValueError("a project name is letters, digits, . _ or -")
    old = project(name)
    keep = lambda key, default: data[key] if key in data else (old[key] if old else default)
    fields = {
        "namespace": str(keep("namespace", "")).strip(),
        "description": str(keep("description", "")).strip(),
        "language": str(keep("language", "")).strip(),
        "tags": json.dumps([str(t) for t in keep("tags", [])]),
        "remotes": json.dumps(clean_remotes(data["remotes"]) if "remotes" in data else old["remotes"] if old else []),
        "name": name, "t": now(),
    }
    with db() as c:
        if old:
            c.execute("UPDATE projects SET namespace=:namespace, description=:description, language=:language, tags=:tags, "
                      "remotes=:remotes, updated=:t WHERE name=:name", fields)
        else:
            c.execute("INSERT INTO projects (name, namespace, description, language, tags, remotes, created, updated) "
                      "VALUES (:name, :namespace, :description, :language, :tags, :remotes, :t, :t)", fields)
    return project(name)


def delete_project(name):
    with db() as c:
        c.execute("DELETE FROM projects WHERE name = ?", (name,))


def next_number(c, table, pid):
    return c.execute(f"SELECT COALESCE(MAX(number), 0) + 1 FROM {table} WHERE project = ?", (pid,)).fetchone()[0]


TASK_SELECT = """SELECT t.*, p.name AS project_name, l.number AS plan_number, l.title AS plan_title FROM tasks t
  JOIN projects p ON p.id = t.project LEFT JOIN plans l ON l.id = t.plan"""


def tasks(pname=None, *, plan=None, state=None):
    where, args = [], []
    if pname:
        where.append("p.name = ?"); args.append(pname)
    if plan:
        where.append("l.number = ?"); args.append(int(plan))
    if state:
        where.append("t.state = ?"); args.append(state)
    sql = TASK_SELECT + (" WHERE " + " AND ".join(where) if where else "") + \
        " ORDER BY t.priority DESC, CASE t.due WHEN '' THEN 1 ELSE 0 END, t.due, t.number"
    with db() as c:
        return [dict(r) for r in c.execute(sql, args)]


def task(pname, number):
    with db() as c:
        row = c.execute(TASK_SELECT + " WHERE p.name = ? AND t.number = ?", (pname, int(number))).fetchone()
    return dict(row) if row else None


def plan_id(pid, value):
    """A plan of this project, by number or title."""
    if value in (None, ""):
        return None
    with db() as c:
        if isinstance(value, int) or str(value).isdigit():
            row = c.execute("SELECT id FROM plans WHERE project = ? AND number = ?", (pid, int(value))).fetchone()
        else:
            row = c.execute("SELECT id FROM plans WHERE project = ? AND lower(title) = lower(?)", (pid, str(value))).fetchone()
    if not row:
        raise ValueError(f"this project has no plan {value}")
    return row[0]


def save_task(pname, data, number=None):
    p = need_project(pname)
    old = task(pname, number) if number else None
    if number and not old:
        raise LookupError("no such task")
    pick = lambda key, default: data[key] if key in data else (old[key] if old else default)
    title = str(pick("title", "")).strip()
    if not title:
        raise ValueError("a task needs a title")
    state = str(pick("state", "todo"))
    if state not in STATE_NAMES:
        raise ValueError("state is todo, doing or done")
    priority = int(pick("priority", 1))
    if priority not in PRIORITIES:
        raise ValueError("priority is 0, 1 or 2")
    row = {"title": title, "notes": str(pick("notes", "")), "state": state, "priority": priority,
           "due": str(pick("due", "")).strip(), "project": p["id"], "t": now(),
           "plan": plan_id(p["id"], data["plan"]) if "plan" in data else (old["plan"] if old else None)}
    row["done_at"] = (old["done_at"] if old and old["state"] == "done" else row["t"]) if state == "done" else ""
    with db() as c:
        if old:
            c.execute("UPDATE tasks SET title=:title, notes=:notes, state=:state, priority=:priority, due=:due, "
                      "plan=:plan, updated=:t, done_at=:done_at WHERE id=:id", {**row, "id": old["id"]})
            number = old["number"]
        else:
            number = next_number(c, "tasks", p["id"])
            c.execute("INSERT INTO tasks (project, number, title, notes, state, priority, due, plan, created, updated, done_at) "
                      "VALUES (:project, :number, :title, :notes, :state, :priority, :due, :plan, :t, :t, :done_at)",
                      {**row, "number": number})
    return task(pname, number)


def delete_task(pname, number):
    with db() as c:
        c.execute("DELETE FROM tasks WHERE number = ? AND project = (SELECT id FROM projects WHERE name = ?)", (int(number), pname))


def quick_text(text, defaults=None):
    """A task from one line: +plan (a number or one word), !high or !low."""
    data = dict(defaults or {})
    words = []
    for word in text.split():
        if word.startswith("+") and len(word) > 1:
            data["plan"] = word[1:]
        elif word in ("!", "!!", "!high"):
            data["priority"] = 2
        elif word == "!low":
            data["priority"] = 0
        else:
            words.append(word)
    data["title"] = " ".join(words)
    return data


PLAN_SELECT = """SELECT l.*, p.name AS project_name,
  (SELECT count(*) FROM tasks t WHERE t.plan = l.id) AS total,
  (SELECT count(*) FROM tasks t WHERE t.plan = l.id AND t.state = 'done') AS done
  FROM plans l JOIN projects p ON p.id = l.project"""


def plans(pname):
    with db() as c:
        return [dict(r) for r in c.execute(PLAN_SELECT + " WHERE p.name = ? ORDER BY l.state DESC, l.number DESC", (pname,))]


def plan(pname, number):
    with db() as c:
        row = c.execute(PLAN_SELECT + " WHERE p.name = ? AND l.number = ?", (pname, int(number))).fetchone()
    return dict(row) if row else None


def save_plan(pname, data, number=None):
    p = need_project(pname)
    old = plan(pname, number) if number else None
    if number and not old:
        raise LookupError("no such plan")
    pick = lambda key, default: data[key] if key in data else (old[key] if old else default)
    title = str(pick("title", "")).strip()
    if not title:
        raise ValueError("a plan needs a title")
    state = str(pick("state", "open"))
    if state not in ("open", "closed"):
        raise ValueError("a plan is open or closed")
    row = {"title": title, "notes": str(pick("notes", "")), "state": state, "t": now(), "project": p["id"]}
    with db() as c:
        if old:
            c.execute("UPDATE plans SET title=:title, notes=:notes, state=:state, updated=:t WHERE id=:id", {**row, "id": old["id"]})
            number = old["number"]
        else:
            number = next_number(c, "plans", p["id"])
            c.execute("INSERT INTO plans (project, number, title, notes, state, created, updated) "
                      "VALUES (:project, :number, :title, :notes, :state, :t, :t)", {**row, "number": number})
    return plan(pname, number)


def delete_plan(pname, number):
    with db() as c:
        c.execute("DELETE FROM plans WHERE number = ? AND project = (SELECT id FROM projects WHERE name = ?)", (int(number), pname))


def make_token(name):
    raw = "wing_" + secrets.token_urlsafe(32)
    with db() as c:
        c.execute("INSERT INTO tokens (name, hash, created) VALUES (?, ?, ?)",
                  (name.strip() or "cli", hashlib.sha256(raw.encode()).hexdigest(), now()))
    return raw


def check_token(raw):
    digest = hashlib.sha256(raw.encode()).hexdigest()
    with db() as c:
        row = c.execute("SELECT id FROM tokens WHERE hash = ?", (digest,)).fetchone()
        if row:
            c.execute("UPDATE tokens SET used = ? WHERE id = ?", (now(), row[0]))
    return bool(row)


# --- What the forge and the builder say about a project. ------------------------------

GITEA_HOST = urlsplit(GITEA).hostname


def gitea_key(url):
    """owner/name of a remote on our gitea, over HTTPS or SSH."""
    match = (re.match(rf"^(?:https?://|ssh://(?:[^@/]+@)?){re.escape(GITEA_HOST)}(?::\d+)?/([^/]+)/([^/]+?)(?:\.git)?/?$", url)
             or re.match(rf"^[^@/]+@{re.escape(GITEA_HOST)}:([^/]+)/([^/]+?)(?:\.git)?$", url))
    return f"{match[1]}/{match[2]}" if match else None


def fetch(base, path, timeout=8):
    parts = urlsplit(base)
    kind = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
    connection = kind(parts.hostname, parts.port, timeout=timeout)
    try:
        connection.request("GET", path, headers={"Accept": "application/json", "User-Agent": "wing"})
        response = connection.getresponse()
        data = response.read()
        return json.loads(data) if response.status == 200 and data else None
    except (OSError, ValueError, http.client.HTTPException):
        return None
    finally:
        connection.close()


class Cache:
    def __init__(self, ttl):
        self.ttl, self.items, self.lock = ttl, {}, threading.Lock()

    def get(self, key, make):
        with self.lock:
            hit = self.items.get(key)
        if hit and time.time() - hit[0] < self.ttl:
            return hit[1]
        value = make()
        with self.lock:
            self.items[key] = (time.time(), value)
        return value


CACHE = Cache(90)
POOL = ThreadPoolExecutor(8)


def repo_api(key, rest="", **params):
    owner, name = key.split("/", 1)
    path = f"/api/v1/repos/{quote(owner, safe='')}/{quote(name, safe='')}{rest}"
    if params:
        path += "?" + urlencode(params)
    return CACHE.get(("gitea", path), lambda: fetch(GITEA, path))


def builds_of(key):
    owner, name = key.split("/", 1)
    path = f"/api/v1/repos/{quote(owner, safe='')}/{quote(name, safe='')}/runs"
    runs = CACHE.get(("muros", path), lambda: fetch(MUROS, path)) or []
    return sorted(runs, key=lambda r: r.get("created_at") or 0, reverse=True)


def muros_repos():
    found = CACHE.get(("muros", "repos"), lambda: fetch(MUROS, "/api/v1/repos")) or []
    return {f"{r['owner']}/{r['name']}" for r in found if isinstance(r, dict)}


def build_key(p):
    """The repository build.bresilla.com builds this project as, if any."""
    known = muros_repos()
    keys = [p["gitea"]] if p["gitea"] else []
    for r in p["remotes"]:
        m = re.search(r"[/:]([^/:]+)/([^/]+?)(?:\.git)?/?$", r["url"])
        if m:
            keys.append(f"{m[1]}/{m[2]}")
    return next((k for k in keys if k in known), None)


def summary(p):
    """The facts a project's tile shows: version, last push, build state."""
    out = {"version": None, "pushed": None, "build": None, "issues": 0, "pulls": 0}
    if p["gitea"]:
        repo = repo_api(p["gitea"]) or {}
        tags = repo_api(p["gitea"], "/tags", limit=1) or []
        out.update(version=tags[0]["name"] if tags else None, pushed=repo.get("updated_at"),
                   issues=repo.get("open_issues_count", 0), pulls=repo.get("open_pr_counter", 0),
                   web=repo.get("html_url"), description=repo.get("description"))
    key = build_key(p)
    if key:
        runs = builds_of(key)
        out["build"] = runs[0]["status"] if runs else "none"
        out["build_url"] = f"{MUROS}/-/repo/pull_based/{key}"
    return out


def summaries(items):
    return dict(zip((p["name"] for p in items), POOL.map(summary, items)))


BUILD_STATE = {"succeeded": "ok", "failed": "fail", "errored": "fail", "cancelled": "warn", "running": "warn",
               "pending": "warn", "queued": "warn", "none": "none"}


def ago(stamp):
    if not stamp:
        return ""
    if isinstance(stamp, (int, float)):
        moment = datetime.fromtimestamp(stamp / 1000, timezone.utc)
    else:
        moment = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
    seconds = (datetime.now(timezone.utc) - moment).total_seconds()
    for size, unit in ((86400 * 365, "y"), (86400 * 30, "mo"), (86400, "d"), (3600, "h"), (60, "m")):
        if seconds >= size:
            return f"{int(seconds // size)}{unit} ago"
    return "just now"


# --- Pages. ---------------------------------------------------------------------------
# Laid out as git.bresilla.com (gitea) lays out a repository: the band with the project's
# "namespace / name" and its tabs, a toolbar of equal-height controls, an open/closed
# switch, then boxes of rows; a side column of boxes on the detail pages.

STYLE = site_ui.STYLE + """
main { max-width: 1280px; }
:root { --h: 34px; }
.band .title a { color: inherit; text-decoration: none; } .band .title a:hover { color: var(--accent-ink); }
.band .title .sep { color: var(--mute); }
.band .summary { display: flex; gap: var(--s2); align-items: center; flex-wrap: wrap; }
.btn, .tb button, .foot button { display: inline-flex; align-items: center; justify-content: center; gap: 6px; height: var(--h);
  padding: 0 14px; box-sizing: border-box; white-space: nowrap; line-height: 1; font-size: var(--site-font-small); margin: 0; }
.btn { border-radius: var(--site-radius); border: 1px solid var(--line-strong); color: var(--fg); text-decoration: none; background: var(--raised);
  transition: background-color .12s ease, border-color .12s ease; }
.btn:hover { background: var(--hover); border-color: var(--accent); }
.btn.primary { background: var(--accent); border-color: var(--accent); color: var(--on-accent); }
.btn.primary:hover { filter: brightness(1.08); }
.btn svg, .tb button svg, .foot button svg, .seg svg { width: 15px; height: 15px; flex: none; }
.btn.sm { height: 28px; padding: 0 10px; }
.tb { display: flex; gap: var(--s2); align-items: center; margin: 0 0 var(--s3); flex-wrap: wrap; }
.tb .spacer { flex: 1; }
.tb input, .tb select { height: var(--h); margin: 0; font-size: var(--site-font-small); }
.tb select { max-width: 200px; }
.joined { display: flex; flex: 1 1 320px; min-width: 0; }
.joined input { flex: 1; min-width: 0; border-top-right-radius: 0; border-bottom-right-radius: 0; }
.joined button { border-top-left-radius: 0; border-bottom-left-radius: 0; }
.seg { display: inline-flex; border: 1px solid var(--line-strong); border-radius: var(--site-radius); overflow: hidden; }
.seg a { display: inline-flex; align-items: center; gap: 6px; height: calc(var(--h) - 2px); padding: 0 12px; color: var(--mute);
  text-decoration: none; font-size: var(--site-font-small); }
.seg a + a { border-left: 1px solid var(--line-strong); }
.seg a:hover { color: var(--fg); background: var(--hover); }
.seg a.on { color: var(--fg); background: color-mix(in srgb, var(--accent) 16%, transparent); }
.box { border: 1px solid var(--line); border-radius: var(--site-radius); background: var(--raised); overflow: hidden; min-width: 0; }
.box + .box { margin-top: var(--s3); }
.bh { display: flex; align-items: center; gap: var(--s2); min-height: 38px; padding: 0 var(--s4); box-sizing: border-box;
  background: color-mix(in srgb, var(--accent) 7%, var(--raised)); border-bottom: 1px solid var(--line); font-size: var(--site-font-small); }
.bh b { font-weight: 600; } .bh .end { margin-left: auto; color: var(--mute); display: flex; gap: var(--s2); align-items: center; }
.bh svg { width: 15px; height: 15px; color: var(--mute); }
.bb { padding: var(--s4); }
.it { display: flex; gap: var(--s3); align-items: center; padding: 10px var(--s4); min-width: 0; transition: background-color .15s ease;
  animation: rise .3s cubic-bezier(.2, .7, .2, 1) both; animation-delay: calc(var(--i, 0) * 18ms); }
.it + .it { border-top: 1px solid var(--line); }
.it:hover { background: var(--hover); }
.it > .ic { flex: none; width: 16px; height: 16px; display: grid; place-items: center; color: var(--mute); align-self: flex-start; margin-top: 2px; }
.it > .ic svg { width: 16px; height: 16px; }
.it .main { flex: 1; min-width: 0; display: grid; gap: 3px; }
.it .ttl { color: var(--fg); text-decoration: none; font-weight: 600; overflow-wrap: anywhere; }
a.ttl:hover { color: var(--accent-ink); }
.it .sub { color: var(--mute); font-size: var(--site-font-tiny); display: flex; gap: 6px; flex-wrap: wrap; align-items: center; }
.it .sub a { color: var(--mute); text-decoration: none; } .it .sub a:hover { color: var(--accent-ink); }
.it .aside { flex: none; display: flex; gap: var(--s2); align-items: center; color: var(--mute); font-size: var(--site-font-small); }
.it .aside form { margin: 0; }
.it.done .ttl { color: var(--mute); font-weight: normal; }
.empty-it { padding: var(--s6) var(--s4); text-align: center; color: var(--mute); }
.ic.todo { color: var(--accent-ink); } .ic.doing { color: var(--warn); } .ic.done { color: var(--ok); }
.ic.ok { color: var(--ok); } .ic.fail { color: var(--bad); } .ic.warn { color: var(--warn); } .ic.none { color: var(--mute); }
.list { border-top: 1px solid var(--line); }
.list .it { padding-left: 0; padding-right: 0; border-bottom: 1px solid var(--line); }
.list .it + .it { border-top: 0; }
.list .it:hover { background: transparent; }
.list .ttl { color: var(--accent-ink); font-size: 15px; }
.list .desc { color: var(--fg); font-size: var(--site-font-small); opacity: .8; }
.cols { display: grid; grid-template-columns: minmax(0, 1fr) 280px; gap: var(--s4); align-items: start; }
.side { display: grid; gap: var(--s3); } .side .box + .box { margin: 0; }
.side .it .ttl { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: block; }
.kv { margin: 0; display: grid; grid-template-columns: auto 1fr; gap: 8px var(--s3); font-size: var(--site-font-small); align-items: center; }
.kv dt { color: var(--mute); } .kv dd { margin: 0; text-align: right; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.prio { font-size: var(--site-font-tiny); }
.chip { display: inline-flex; align-items: center; height: 20px; border: 1px solid var(--line-strong); border-radius: 4px; padding: 0 6px;
  font-size: var(--site-font-tiny); color: var(--mute); text-decoration: none; }
a.chip:hover { color: var(--accent-ink); border-color: var(--accent); }
.chips { display: flex; gap: 6px; flex-wrap: wrap; }
.bar { margin: 0; width: 100%; max-width: 260px; }
.progress { display: flex; align-items: center; gap: var(--s2); font-size: var(--site-font-tiny); color: var(--mute); min-width: 180px; }
.notes { white-space: pre-wrap; overflow-wrap: anywhere; }
.title-row { display: flex; align-items: center; gap: var(--s3); flex-wrap: wrap; margin: 0 0 var(--s2); }
.title-row h2 { margin: 0; font-size: 22px; font-weight: normal; overflow-wrap: anywhere; } .title-row h2 .num { color: var(--mute); }
.title-row .end { margin-left: auto; display: flex; gap: var(--s2); }
.meta-row { display: flex; gap: var(--s2); align-items: center; flex-wrap: wrap; color: var(--mute); font-size: var(--site-font-small);
  padding: 0 0 var(--s4); margin: 0 0 var(--s4); border-bottom: 1px solid var(--line); }
.form { display: grid; gap: var(--s4); }
.form label { display: grid; gap: 6px; font-size: var(--site-font-small); color: var(--mute); }
.form label > * { color: var(--fg); font-size: var(--site-font-size); width: 100%; margin: 0; box-sizing: border-box; }
.form input, .form select { height: var(--h); }
.form .two { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: var(--s4); }
.form .foot { display: flex; justify-content: space-between; gap: var(--s2); }
.picks { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 0 var(--s4); }
.picks label { display: flex; gap: var(--s2); align-items: center; padding: 6px 0; cursor: pointer; min-width: 0; font-size: var(--site-font-small); }
.picks label span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.picks input { margin: 0; flex: none; }
.token { font-family: var(--site-font-mono, monospace); padding: var(--s3); border: 1px dashed var(--accent); border-radius: var(--site-radius); overflow-wrap: anywhere; }
.it .sub svg, .it .aside svg { width: 13px; height: 13px; vertical-align: -2px; }
.it .aside > span { display: inline-flex; align-items: center; gap: 4px; }
.pick .pick-button { height: var(--h); padding-top: 0; padding-bottom: 0; font-size: var(--site-font-small); }
.form .pick .pick-button { font-size: var(--site-font-size); }
.side button { height: var(--h); padding: 0 14px; }
.title-row h2 { color: var(--fg); }
.joined .pick { flex: none; width: 170px; } .joined .pick .pick-button { border-top-right-radius: 0; border-bottom-right-radius: 0; border-right: 0; }
@keyframes rise { from { opacity: 0; transform: translateY(3px); } to { opacity: 1; transform: none; } }
@media (prefers-reduced-motion: reduce) { .it { animation: none; } }
@media (max-width: 900px) { .cols { grid-template-columns: 1fr; } .tb select { max-width: none; flex: 1 1 100%; }
  .it { flex-wrap: wrap; } .it .aside { width: 100%; padding-left: 28px; flex-wrap: wrap; } .list .it .aside { padding-left: 28px; }
  .joined { flex-basis: 100%; } .tb > .btn { flex: 1; }
  .progress { min-width: 0; } .it .aside { box-sizing: border-box; } }
@media (max-width: 520px) { header > a, header .who .mute { display: none; } header nav a { padding-left: 8px; padding-right: 8px; }
  header nav { min-width: 0; flex: 1 1 auto; overflow-x: auto; scrollbar-width: none; } header .who { flex: none; }
  .upload { width: 100%; } .upload input { flex: 1 1 100%; max-width: none !important; width: auto !important; } }
"""

_SVG = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">{}</svg>'
STATE_ICON = {
    "todo": _SVG.format('<circle cx="8" cy="8" r="6"/><circle cx="8" cy="8" r="1.2" fill="currentColor"/>'),
    "doing": _SVG.format('<circle cx="8" cy="8" r="6"/><path d="M8 2a6 6 0 0 1 0 12z" fill="currentColor"/>'),
    "done": _SVG.format('<circle cx="8" cy="8" r="6"/><path d="M5.5 8.2l1.8 1.8 3.4-3.6"/>'),
}
PLAN_ICON = _SVG.format('<path d="M3 13V3"/><path d="M3 3h8l-1.5 2.5L11 8H3"/>')


def page(title, body, name, here, active="projects"):
    out = site_ui.page(site=SITE, title=title, body=body, links=LINKS, active=active, name=name, here=here, style=STYLE)
    return out.replace("</title>", '</title><link rel=icon href="/favicon.svg">', 1)


def options(items, chosen, blank="—"):
    out = f'<option value="">{e(blank)}</option>' if blank is not None else ""
    for value, label in items:
        out += f'<option value="{e(str(value))}"{" selected" if str(value) == str(chosen or "") else ""}>{e(label)}</option>'
    return out


def purl(pname, rest=""):
    return f"/p/{quote(pname)}{rest}"


def btn(href, label, ico="", primary=False, small=False):
    kind = "btn" + (" primary" if primary else "") + (" sm" if small else "")
    return f'<a class="{kind}" href="{e(href)}">{site_ui.icon(ico)}{e(label)}</a>'


def box(title, body, ico="", end="", padded=True):
    head = f'<div class=bh>{site_ui.icon(ico)}<b>{e(title)}</b>{f"<span class=end>{end}</span>" if end else ""}</div>' if title else ""
    return f'<div class=box>{head}{f"<div class=bb>{body}</div>" if padded else body}</div>'


def items(rows, empty):
    return "".join(rows) if rows else f'<div class=empty-it>{e(empty)}</div>'


def item(ic, title, sub="", aside="", href=None, i=0, kind="", ic_class=""):
    ttl = f'<a class=ttl href="{e(href)}">{title}</a>' if href else f'<span class=ttl>{title}</span>'
    return (f'<div class="it {kind}" style="--i:{i}"><span class="ic {ic_class}">{ic}</span><div class=main>{ttl}'
            f'{f"<div class=sub>{sub}</div>" if sub else ""}</div>{f"<div class=aside>{aside}</div>" if aside else ""}</div>')


def seg(choices):
    """choices: (href, icon html, label, on)."""
    return '<div class=seg>' + "".join(f'<a href="{e(h)}" class="{"on" if on else ""}">{ic}{e(label)}</a>' for h, ic, label, on in choices) + "</div>"


def field(label, control):
    return f"<label>{e(label)}{control}</label>"


def form(action, fields, save="Save", delete=None):
    remove = (f'<button class=danger name=delete value=1 formnovalidate onclick="return confirm({e(json.dumps(delete))})">'
              f'{site_ui.icon("trash")}Delete</button>') if delete else ""
    return f'<form method=post action="{e(action)}" class=form>{fields}<div class=foot><button>{e(save)}</button>{remove}</div></form>'


def adder(action, placeholder, hidden=None, label="Add", pick=""):
    extra = "".join(f'<input type=hidden name="{k}" value="{e(str(v))}">' for k, v in (hidden or {}).items())
    return (f'<form method=post action="{e(action)}" class="joined">{extra}{pick}'
            f'<input name=quick placeholder="{e(placeholder)}" autocomplete=off required>'
            f'<button>{site_ui.icon("plus")}{e(label)}</button></form>')


def progress(l):
    share = l["done"] / l["total"] if l["total"] else 0
    return (f'<span class=progress><span class=bar><i class=ok style="width:{share * 100:.0f}%"></i></span>'
            f'{share:.0%}</span>')


def short(url):
    return re.sub(r"^https?://", "", url).removesuffix(".git")


# Tasks as rows ---------------------------------------------------------------------------

NEXT = {"todo": [("doing", "Start")], "doing": [("done", "Done"), ("todo", "Stop")], "done": [("todo", "Reopen")]}


def task_row(t, i=0, back="", every=False):
    base = purl(t["project_name"])
    sub = []
    if every:
        sub.append(f'<a class=chip href="{base}">{e(t["project_name"])}</a>')
    sub.append(f'#{t["number"]}')
    if t["plan_title"]:
        sub.append(f'<a href="{base}/plans/{t["plan_number"]}">{PLAN_ICON} {e(t["plan_title"])}</a>')
    if t["due"]:
        sub.append(f'due {e(t["due"])}')
    sub.append(e(("done " + ago(t["done_at"])) if t["state"] == "done" and t["done_at"] else "updated " + ago(t["updated"])))
    moves = "".join(f'<form method=post action="{base}/t/{t["number"]}"><input type=hidden name=state value={to}>'
                    f'<input type=hidden name=back value="{e(back or base)}"><button class="ghost small">{label}</button></form>'
                    for to, label in NEXT[t["state"]])
    prio = {2: site_ui.pill("fail", "high"), 0: site_ui.pill("none", "low")}.get(t["priority"], "")
    return item(STATE_ICON[t["state"]], e(t["title"]), " · ".join(sub), f'{prio}<span class=hide-sm style="display:contents">{moves}</span>',
                f'{base}/t/{t["number"]}', i, t["state"], t["state"])


def task_box(all_items, show, back, every=False, filters=""):
    """show: open or done. Open lists what is being done first."""
    open_items = [t for t in all_items if t["state"] != "done"]
    done_items = sorted([t for t in all_items if t["state"] == "done"], key=lambda t: t["done_at"], reverse=True)
    shown = done_items if show == "done" else sorted(open_items, key=lambda t: t["state"] != "doing")
    clean = re.sub(r"[?&]show=\w+", "", back)
    join = "&" if "?" in clean else "?"
    switch = seg([(clean, STATE_ICON["todo"], f"{len(open_items)} Open", show != "done"),
                  (f"{clean}{join}show=done", STATE_ICON["done"], f"{len(done_items)} Done", show == "done")])
    rows = [task_row(t, i, back, every) for i, t in enumerate(shown[:200])]
    return f'<div class=tb>{switch}<span class=spacer></span>{filters}</div><div class=box>{items(rows, "nothing here")}</div>'


# Projects --------------------------------------------------------------------------------

def open_counts():
    counts = {}
    for t in tasks():
        if t["state"] != "done":
            counts.setdefault(t["project_name"], {"todo": 0, "doing": 0})[t["state"]] += 1
    return counts


def projects_page(name, query):
    items_ = projects()
    spaces = sorted({p["namespace"] for p in items_ if p["namespace"]})
    chosen = (query.get("ns") or [""])[0]
    needle = (query.get("q") or [""])[0].strip().lower()
    shown = [p for p in items_ if (not chosen or p["namespace"] == chosen)
             and (not needle or needle in f'{p["namespace"]}/{p["name"]} {p["description"]}'.lower())]
    info = summaries(shown)
    counts = open_counts()
    tabs = [("/", "All", "folder", len(items_), None, not chosen)] + \
           [(f"/?ns={quote(s)}", s, "org", sum(p["namespace"] == s for p in items_), None, s == chosen) for s in spaces]
    band = site_ui.band("Projects", "folder", items=tabs)
    keep = f'<input type=hidden name=ns value="{e(chosen)}">' if chosen else ""
    bar = (f'<div class=tb><form method=get class=joined>{keep}<input name=q value="{e(needle)}" placeholder="Search projects…">'
           f'<button class=ghost>{site_ui.icon("search")}</button></form>'
           f'{btn("/import", "Import from git", "download")}{btn("/new", "New project", "plus", primary=True)}</div>')
    rows = []
    for i, p in enumerate(sorted(shown, key=lambda p: info[p["name"]]["pushed"] or p["updated"], reverse=True)):
        s = info[p["name"]]
        c = counts.get(p["name"], {"todo": 0, "doing": 0})
        ns = f'{e(p["namespace"])} <span class=sep>/</span> ' if p["namespace"] else ""
        desc = p["description"] or s.get("description") or ""
        sub = (f'<span class=desc>{e(desc)}</span>' if desc else "")
        when = f'Updated {e(ago(s["pushed"] or p["updated"]))}'
        state = BUILD_STATE.get(s["build"]) if s["build"] else None
        aside = ((f'<span class=chip>{e(p["language"])}</span>' if p["language"] else "")
                 + (f'<span class=chip>{e(s["version"])}</span>' if s["version"] else "")
                 + f'<span title="doing / to do">{STATE_ICON["doing"]} {c["doing"]} · {STATE_ICON["todo"]} {c["todo"]}</span>'
                 + (site_ui.pill(state, s["build"]) if state else ""))
        rows.append(f'<div class=it style="--i:{i}"><span class="ic">{site_ui.icon("repo")}</span><div class=main>'
                    f'<a class=ttl href="{purl(p["name"])}">{ns}{e(p["name"])}</a>{sub}<div class=sub>{when}</div></div>'
                    f'<div class=aside>{aside}</div></div>')
    listing = f'<div class=list>{"".join(rows)}</div>' if rows else \
        '<div class=empty-it>No projects yet: register one with <code>wing project add</code>, make one, or import from git.</div>'
    return page("projects", band + bar + listing, name, "/")


def new_project_page(name):
    band = site_ui.band("New project", "plus", crumbs=[("/", "projects")])
    fields = (field("Name", '<input name=name required pattern="[A-Za-z0-9._-]+" autofocus>')
              + '<div class=two>' + field("Namespace", "<input name=namespace>") + field("Language", "<input name=language>") + "</div>"
              + field("Description", "<input name=description>")
              + field("Remote", '<input name=remote placeholder="https://git.bresilla.com/owner/name">'))
    return page("new project", band + f'<div class=cols><div>{box("Project", form("/projects", fields, "Create"), "folder")}</div></div>', name, "/new")


def gitea_repos():
    found, pageno = [], 1
    while pageno < 20:
        chunk = fetch(GITEA, f"/api/v1/repos/search?limit=50&page={pageno}") or {}
        data = chunk.get("data") or []
        found += data
        if len(data) < 50:
            break
        pageno += 1
    return found


def import_page(name):
    have = {p["gitea"] for p in projects() if p["gitea"]}
    repos = [r for r in CACHE.get(("gitea", "all"), gitea_repos) if r["full_name"] not in have]
    band = site_ui.band("Import from git", "download", crumbs=[("/", "projects")])
    if not repos:
        return page("import", band + '<div class=box><div class=empty-it>Every repository on git is registered.</div></div>', name, "/import")
    owners = {}
    for r in sorted(repos, key=lambda r: r["full_name"].lower()):
        owners.setdefault(r["owner"]["login"], []).append(r)
    groups = "".join(box(owner, '<div class=picks>' + "".join(
        f'<label><input type=checkbox name=repo value="{e(r["full_name"])}"><span>{e(r["name"])}</span></label>' for r in rs) + "</div>",
        "org", f"{len(rs)}") for owner, rs in owners.items())
    bar = (f'<div class=tb><span class=mute>{len(repos)} repositories on git are not projects here yet.</span><span class=spacer></span>'
           f'<button>{site_ui.icon("download")}Import selected</button></div>')
    return page("import", band + f'<form method=post action="/import">{bar}{groups}</form>', name, "/import")


def import_from_gitea(keys):
    known = {r["full_name"]: r for r in CACHE.get(("gitea", "all"), gitea_repos)}
    for key in keys:
        r = known.get(key)
        if r:
            name = r["name"] if not project(r["name"]) else key.replace("/", "-")
            save_project({"name": name, "namespace": r["owner"]["login"], "description": r.get("description") or "",
                          "language": r.get("language") or "", "remotes": [{"name": "origin", "url": r["html_url"]}]})


# One project -----------------------------------------------------------------------------

def project_band(p, s, view):
    base = purl(p["name"])
    mine = tasks(p["name"])
    ps = plans(p["name"])
    tabs = [(base, "Tasks", "check", sum(t["state"] != "done" for t in mine), None, view == "tasks"),
            (base + "/plans", "Plans", "pin", sum(l["state"] == "open" for l in ps), None, view == "plans"),
            (base + "?v=builds", "Builds", "builds", None, None, view == "builds"),
            (base + "?v=git", "Git", "code", None, None, view == "git"),
            (base + "?v=edit", "Settings", "settings", None, None, view == "edit")]
    ns = f'<a href="/?ns={quote(p["namespace"])}">{e(p["namespace"])}</a> <span class=sep>/</span> ' if p["namespace"] else ""
    state = BUILD_STATE.get(s["build"]) if s["build"] else None
    links = (site_ui.pill(state, s["build"]) if state else "") + \
            (f'<span class=chip>{e(s["version"])}</span>' if s["version"] else "") + \
            (btn(f'{GITEA}/{p["gitea"]}', "git", "repo", small=True) if p["gitea"] else "") + \
            (btn(s["build_url"], "build", "builds", small=True) if s.get("build_url") else "")
    head = (f'<div class=head><div class=title>{site_ui.icon("repo")}{ns}<a href="{base}">{e(p["name"])}</a></div>'
            f'<div class=summary>{links}</div></div>')
    return f'<div class=band>{head}{site_ui.tabs(tabs)}</div>'


def project_side(p, s):
    about = p["description"] or s.get("description") or ""
    facts = [("language", p["language"]), ("version", s["version"]), ("pushed", ago(s["pushed"])),
             ("issues", f'{s["issues"]} open' if p["gitea"] else ""), ("pulls", f'{s["pulls"]} open' if p["gitea"] else "")]
    kv = "".join(f"<dt>{k}</dt><dd>{e(str(v))}</dd>" for k, v in facts if v)
    tags = f'<div class=chips style="margin-top:var(--s3)">{"".join(f"<span class=chip>{e(t)}</span>" for t in p["tags"])}</div>' if p["tags"] else ""
    body = (f'<div class=notes style="margin-bottom:var(--s3)">{e(about)}</div>' if about else "") + f"<dl class=kv>{kv}</dl>{tags}"
    return f'<div class=side>{box("About", body, "book")}{box("Remotes", remotes_view(p, s), "globe", padded=False)}</div>'


def remotes_view(p, s):
    rows = []
    for r in p["remotes"]:
        url = r["url"]
        web = f"{GITEA}/{gitea_key(url)}" if gitea_key(url) else url if url.startswith("http") else None
        rows.append(item(site_ui.icon("globe"), e(short(url)), e(r["name"]), href=web))
    if s.get("build_url"):
        rows.append(item(site_ui.icon("builds"), e(short(s["build_url"])), "build", href=s["build_url"]))
    return items(rows, "no remotes")


def frame(name, p, view, main, title, here, side=True):
    s = summary(p)
    inner = f'<div class=cols><div>{main}</div>{project_side(p, s)}</div>' if side else main
    return page(title, project_band(p, s, view) + inner, name, here)


def project_page(name, pname, query):
    p = project(pname)
    if not p:
        return None
    view = (query.get("v") or ["tasks"])[0]
    base = purl(pname)
    if view == "builds":
        return frame(name, p, view, builds_view(p), f"builds · {pname}", base + "?v=builds")
    if view == "git":
        return frame(name, p, view, git_view(p), f"git · {pname}", base + "?v=git")
    if view == "edit":
        return frame(name, p, view, edit_project(p), f"settings · {pname}", base + "?v=edit")
    show = (query.get("show") or ["open"])[0]
    here = base + ("?show=done" if show == "done" else "")
    bar = f'<div class=tb>{adder(base + "/tasks", "New task — +plan !high", {"back": here})}{btn(base + "/plans", "Plans", "pin")}</div>'
    return frame(name, p, "tasks", bar + task_box(tasks(pname), show, here), pname, here)


def builds_view(p):
    key = build_key(p)
    if not key:
        return box("Builds", '<div class=empty-it>build.bresilla.com does not build this project.</div>', "builds", padded=False)
    rows = []
    for i, r in enumerate(builds_of(key)[:20]):
        st = BUILD_STATE.get(r["status"], "none")
        sub = f'<code>{e(r["commit"][:8])}</code> · {e(r.get("branch", ""))} · {e(ago(r.get("created_at")))}'
        rows.append(item(STATE_ICON["done"] if st == "ok" else site_ui.icon("x") if st == "fail" else STATE_ICON["doing"],
                         e(r["status"]), sub, e((r.get("error") or "")[:80]), i=i, ic_class=st))
    return box("Builds", items(rows, "no builds yet"), "builds", f'<a href="{e(MUROS)}/-/repo/pull_based/{e(key)}">{e(key)}</a>', padded=False)


def git_view(p):
    key = p["gitea"]
    if not key:
        return box("Git", '<div class=empty-it>No remote on git.bresilla.com.</div>', "code", padded=False)
    repo = repo_api(key) or {}
    branch = repo.get("default_branch", "main")
    commits = repo_api(key, "/commits", limit=10, sha=branch, stat="false", verification="false", files="false") or []
    tags = repo_api(key, "/tags", limit=12) or []
    issues = repo_api(key, "/issues", state="open", type="issues", limit=10) or []
    pulls = repo_api(key, "/pulls", state="open", limit=10) or []
    web = f"{GITEA}/{key}"
    log = [item(site_ui.icon("history"), e(c["commit"]["message"].splitlines()[0] if c["commit"]["message"] else ""),
                f'<code>{e(c["sha"][:10])}</code> · {e(c["commit"]["author"]["name"])} · {e(ago(c["commit"]["author"]["date"]))}',
                href=f"{web}/commit/{c['sha']}", i=i) for i, c in enumerate(commits)]
    numbered = lambda rs, ico: [item(ico, e(r["title"]), f'#{r["number"]} · {e(ago(r["updated_at"]))}', href=r["html_url"], i=i) for i, r in enumerate(rs)]
    chips = "".join(f'<a class=chip href="{e(web)}/src/tag/{quote(t["name"])}">{e(t["name"])}</a>' for t in tags)
    return (box("Commits", items(log, "no commits"), "history", f'<a href="{e(web)}/commits/branch/{quote(branch)}">{e(branch)}</a>', padded=False)
            + box("Tags", f"<div class=chips>{chips}</div>" if tags else '<span class=mute>no tags</span>', "pin")
            + box("Issues", items(numbered(issues, STATE_ICON["todo"]), "no open issues"), "news", f'<a href="{e(web)}/issues">all</a>', padded=False)
            + box("Pull requests", items(numbered(pulls, site_ui.icon("pull")), "no open pull requests"), "pull", f'<a href="{e(web)}/pulls">all</a>', padded=False))


def edit_project(p):
    remotes = "\n".join(f'{r["name"]} {r["url"]}' for r in p["remotes"])
    fields = ('<div class=two>' + field("Namespace", f'<input name=namespace value="{e(p["namespace"])}">')
              + field("Language", f'<input name=language value="{e(p["language"])}">') + "</div>"
              + field("Description", f'<input name=description value="{e(p["description"])}">')
              + field("Tags", f'<input name=tags value="{e(", ".join(p["tags"]))}" placeholder="comma, separated">')
              + field("Remotes, one per line: name url", f'<textarea name=remotes rows=4 placeholder="origin https://git.bresilla.com/owner/name">{e(remotes)}</textarea>'))
    return box("Settings", form(purl(p["name"]), fields, delete=f'Delete {p["name"]} with all its tasks and plans?'), "settings")


def task_page(name, pname, number):
    p = project(pname)
    t = task(pname, number) if p else None
    if not t:
        return None
    base = purl(pname)
    here = f"{base}/t/{t['number']}"
    state = site_ui.pill({"done": "ok", "doing": "warn"}.get(t["state"], "none"), STATE_NAMES[t["state"]])
    title = (f'<div class=title-row><h2>{e(t["title"])} <span class=num>#{t["number"]}</span></h2>'
             f'<span class=end>{btn(base, "All tasks", "check")}</span></div>'
             f'<div class=meta-row>{state}<span>opened {e(ago(t["created"]))} · updated {e(ago(t["updated"]))}'
             f'{" · done " + e(ago(t["done_at"])) if t["done_at"] else ""}</span></div>')
    fields = (field("Title", f'<input name=title value="{e(t["title"])}" required>')
              + field("Notes", f'<textarea name=notes rows=10 placeholder="What it takes, links, decisions…">{e(t["notes"])}</textarea>')
              + '<div class=two>' + field("State", f'<select name=state>{options(STATES, t["state"], None)}</select>')
              + field("Priority", f'<select name=priority>{options(sorted(PRIORITIES.items(), reverse=True), t["priority"], None)}</select>')
              + field("Plan", f'<select name=plan>{options([(l["number"], l["title"]) for l in plans(pname)], t["plan_number"])}</select>')
              + field("Due", f'<input type=date name=due value="{e(t["due"])}">') + "</div>"
              + f'<input type=hidden name=back value="{e(here)}">')
    moves = "".join(f'<form method=post action="{here}"><input type=hidden name=state value={to}><input type=hidden name=back value="{e(here)}">'
                    f'<button class="ghost" style="width:100%">{label}</button></form>' for to, label in NEXT[t["state"]])
    side_facts = [("state", STATE_NAMES[t["state"]]), ("priority", PRIORITIES[t["priority"]]),
                  ("plan", t["plan_title"] or "none"), ("due", t["due"] or "none")]
    side = (box("Status", f'<dl class=kv>{"".join(f"<dt>{k}</dt><dd>{e(v)}</dd>" for k, v in side_facts)}</dl>'
                f'<div style="display:grid;gap:var(--s2);margin-top:var(--s4)">{moves}</div>', "check"))
    body = title + f'<div class=cols><div>{box("", form(here, fields, delete=f"Delete task #{number}?"))}</div><div class=side>{side}</div></div>'
    return page(f'#{t["number"]} {t["title"]} · {pname}', project_band(p, summary(p), "tasks") + body, name, here)


def plans_page(name, pname, query):
    p = project(pname)
    if not p:
        return None
    base = purl(pname)
    show = (query.get("show") or ["open"])[0]
    every = plans(pname)
    open_ = [l for l in every if l["state"] == "open"]
    closed = [l for l in every if l["state"] == "closed"]
    switch = seg([(base + "/plans", PLAN_ICON, f"{len(open_)} Open", show != "closed"),
                  (base + "/plans?show=closed", STATE_ICON["done"], f"{len(closed)} Closed", show == "closed")])
    rows = [item(PLAN_ICON, e(l["title"]), f'{l["total"] - l["done"]} open · {l["done"]} done · updated {e(ago(l["updated"]))}',
                 progress(l), f'{base}/plans/{l["number"]}', i) for i, l in enumerate(closed if show == "closed" else open_)]
    bar = (f'<div class=tb><form method=post action="{base}/plans" class=joined><input name=title placeholder="New plan — a title; notes after" '
           f'autocomplete=off required><button>{site_ui.icon("plus")}Create</button></form></div>')
    main = bar + f'<div class=tb>{switch}</div><div class=box>{items(rows, "no plans here")}</div>'
    return frame(name, p, "plans", main, f"plans · {pname}", base + "/plans")


def plan_page(name, pname, number, query):
    p = project(pname)
    l = plan(pname, number) if p else None
    if not l:
        return None
    base = purl(pname)
    here = f"{base}/plans/{l['number']}"
    state = site_ui.pill("ok" if l["state"] == "closed" else "warn", l["state"])
    editing = (query.get("v") or [""])[0] == "edit"
    title = (f'<div class=title-row><h2>{e(l["title"])}</h2><span class=end>'
             f'{btn(here, "Back to plan") if editing else btn(here + "?v=edit", "Edit", "settings")}{btn(base + "/plans", "All plans", "pin")}</span></div>'
             f'<div class=meta-row>{state}{progress(l)}<span>{l["total"] - l["done"]} open · {l["done"]} done · updated {e(ago(l["updated"]))}</span></div>')
    if editing:
        fields = (field("Title", f'<input name=title value="{e(l["title"])}" required>')
                  + field("State", f'<select name=state>{options([("open", "open"), ("closed", "closed")], l["state"], None)}</select>')
                  + field("Notes", f'<textarea name=notes rows=14>{e(l["notes"])}</textarea>'))
        main = title + box("", form(here, fields, delete="Delete this plan? Its tasks stay."))
        return frame(name, p, "plans", main, f"edit {l['title']} · {pname}", here + "?v=edit", side=False)
    show = (query.get("show") or ["open"])[0]
    view = here + ("?show=done" if show == "done" else "")
    notes = box("Notes", f'<div class=notes>{e(l["notes"])}</div>', "book") if l["notes"] else ""
    bar = f'<div class=tb>{adder(base + "/tasks", "New task in this plan — !high", {"plan": l["number"], "back": view})}</div>'
    main = title + notes + (f'<div style="height:var(--s4)"></div>' if notes else "") + bar + task_box(tasks(pname, plan=l["number"]), show, view)
    return frame(name, p, "plans", main, f"{l['title']} · {pname}", view, side=False)


# Everything else -------------------------------------------------------------------------

def all_tasks_page(name, query):
    chosen = (query.get("project") or [""])[0]
    show = (query.get("show") or ["open"])[0]
    every = tasks()
    names = [p["name"] for p in projects()]
    open_by = {}
    for t in every:
        if t["state"] != "done":
            open_by[t["project_name"]] = open_by.get(t["project_name"], 0) + 1
    tabs = [("/tasks", "All", "check", sum(open_by.values()), None, not chosen)] + \
           [(f"/tasks?project={quote(n)}", n, "folder", open_by[n], None, n == chosen) for n in names if open_by.get(n) or n == chosen]
    here = "/tasks" + (f"?project={quote(chosen)}" if chosen else "")
    view = here + (("&" if chosen else "?") + "show=done" if show == "done" else "")
    band = site_ui.band("Tasks", "check", summary=btn(purl(chosen), chosen, "repo", small=True) if chosen else "", items=tabs)
    bar = ""
    if names:
        if chosen:
            bar = f'<div class=tb>{adder(purl(chosen, "/tasks"), f"New task in {chosen} — +plan !high", {"back": view})}</div>'
        else:
            pick = f'<select name=project required style="border-radius:var(--site-radius) 0 0 var(--site-radius);border-right:0;max-width:180px">{options([(n, n) for n in names], "", "project…")}</select>'
            bar = f'<div class=tb>{adder("/tasks", "New task — +plan !high", {"back": view}, pick=pick)}</div>'
    shown = [t for t in every if not chosen or t["project_name"] == chosen]
    return page("tasks", band + bar + task_box(shown, show, view, every=not chosen), name, view, "tasks")


def settings_page(name, fresh=None):
    with db() as c:
        rows = [item(site_ui.icon("key"), e(r["name"]),
                     f'made {e(ago(r["created"]))} · {"used " + e(ago(r["used"])) if r["used"] else "never used"}',
                     f'<form method=post action="/settings"><input type=hidden name=revoke value={r["id"]}>'
                     f'<button class="danger small">Revoke</button></form>', i=i)
                for i, r in enumerate(c.execute("SELECT * FROM tokens ORDER BY id"))]
    shown = (box("New token", f'<p style="margin-top:0">Copy it now; it is not shown again.</p><div class=token>{e(fresh)}</div>'
                 f'<p class=mute style="margin-bottom:0">On your machine: <code>wing server login https://{e(DOMAIN)} --token …</code></p>', "key")
             + '<div style="height:var(--s4)"></div>') if fresh else ""
    bar = (f'<div class=tb><form method=post action="/settings" class=joined><input name=token placeholder="Token name — the machine, e.g. core" '
           f'autocomplete=off required><button>{site_ui.icon("key")}Make a token</button></form></div>')
    body = site_ui.band("Settings", "settings") + shown + bar + box("Tokens for the wing CLI", items(rows, "no tokens yet"), "key", padded=False)
    return page("settings", body, name, "/settings", "settings")


# --- Templates. -----------------------------------------------------------------------
# What the wing CLI makes projects from: each template is a folder of files (template.lua,
# init.lua, base/, flavours/ ...), and common/ is the folder every template shares. The CLI
# pulls them all into one of its template roots; the page edits them file by file.

TEMPLATE_NAME = re.compile(r"[A-Za-z0-9._-]{1,64}")
MAX_FILE = 4 << 20
STARTER = '''local wing = require("wing")

wing.template("{name}", {{
  description = "{description}",
  language = "",
  tags = {{ }},
}})
'''


def clean_path(path):
    """A relative file path inside a template; nothing that climbs out of it."""
    parts = [p for p in str(path).replace("\\", "/").split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts) or len("/".join(parts)) > 400:
        raise ValueError(f"not a usable file path: {path!r}")
    return "/".join(parts)


def described(files):
    lua = next((f["data"] for f in files if f["path"] == "template.lua"), b"")
    match = re.search(rb'description\s*=\s*"((?:[^"\\]|\\.)*)"', lua)
    return match[1].decode(errors="replace") if match else ""


def templates_all():
    with db() as c:
        rows = c.execute("""SELECT t.*, count(f.id) AS files, COALESCE(sum(length(f.data)), 0) AS size FROM templates t
                            LEFT JOIN template_files f ON f.template = t.id GROUP BY t.id ORDER BY t.name""").fetchall()
    return [dict(r) for r in rows]


def template_row(name):
    with db() as c:
        row = c.execute("SELECT * FROM templates WHERE name = ?", (name,)).fetchone()
    return dict(row) if row else None


def template_files(name, with_data=False):
    cols = "f.path, f.mode, f.updated, length(f.data) AS size" + (", f.data" if with_data else "")
    with db() as c:
        return [dict(r) for r in c.execute(f"SELECT {cols} FROM template_files f JOIN templates t ON t.id = f.template "
                                           "WHERE t.name = ? ORDER BY f.path", (name,))]


def template_file(name, path):
    with db() as c:
        row = c.execute("SELECT f.* FROM template_files f JOIN templates t ON t.id = f.template WHERE t.name = ? AND f.path = ?",
                        (name, path)).fetchone()
    return dict(row) if row else None


def template_hash(files):
    digest = hashlib.sha256()
    for f in sorted(files, key=lambda f: f["path"]):
        digest.update(f["path"].encode() + b"\0" + str(f["mode"]).encode() + b"\0" + hashlib.sha256(f["data"]).digest())
    return digest.hexdigest()


def need_template(name):
    t = template_row(name)
    if not t:
        raise LookupError(f"no template named {name}")
    return t


def create_template(name, description=""):
    if not TEMPLATE_NAME.fullmatch(name or ""):
        raise ValueError("a template name is letters, digits, . _ or -")
    if template_row(name):
        raise ValueError(f"there is already a template named {name}")
    with db() as c:
        tid = c.execute("INSERT INTO templates (name, description, created, updated) VALUES (?, ?, ?, ?)",
                        (name, description, now(), now())).lastrowid
        if name != "common":
            c.execute("INSERT INTO template_files (template, path, data, mode, updated) VALUES (?, 'template.lua', ?, 420, ?)",
                      (tid, STARTER.format(name=name, description=description.replace('"', "'")).encode(), now()))
    return template_row(name)


def touch_template(c, tid):
    files = [dict(r) for r in c.execute("SELECT path, data FROM template_files WHERE template = ?", (tid,))]
    c.execute("UPDATE templates SET updated = ?, description = ? WHERE id = ?", (now(), described(files), tid))


def save_template_file(name, path, data, mode=None, rename=None):
    t = need_template(name)
    path = clean_path(path)
    if len(data) > MAX_FILE:
        raise ValueError("a template file is at most 4 MB")
    target = clean_path(rename) if rename else path
    with db() as c:
        old = c.execute("SELECT mode FROM template_files WHERE template = ? AND path = ?", (t["id"], path)).fetchone()
        keep = mode if mode is not None else (old[0] if old else 420)
        if target != path:
            if c.execute("SELECT 1 FROM template_files WHERE template = ? AND path = ?", (t["id"], target)).fetchone():
                raise ValueError(f"{target} already exists")
            c.execute("DELETE FROM template_files WHERE template = ? AND path = ?", (t["id"], path))
        c.execute("INSERT INTO template_files (template, path, data, mode, updated) VALUES (?, ?, ?, ?, ?) "
                  "ON CONFLICT (template, path) DO UPDATE SET data = excluded.data, mode = excluded.mode, updated = excluded.updated",
                  (t["id"], target, data, keep, now()))
        touch_template(c, t["id"])
    return target


def delete_template_file(name, path):
    t = need_template(name)
    with db() as c:
        c.execute("DELETE FROM template_files WHERE template = ? AND (path = ? OR path LIKE ?)", (t["id"], path, path + "/%"))
        touch_template(c, t["id"])


def replace_template(name, files, create=True):
    """Every file of a template at once, as the CLI pushes it."""
    if name == "new":
        raise ValueError("new is taken by the page that makes templates")
    clean = []
    for f in files:
        data = base64.b64decode(f.get("data", ""))
        if len(data) > MAX_FILE:
            raise ValueError(f"{f.get('path')} is over 4 MB")
        clean.append((clean_path(f["path"]), data, int(f.get("mode", 420)) & 0o777))
    if not template_row(name):
        if not create:
            raise LookupError(f"no template named {name}")
        create_template(name)
    t = template_row(name)
    with db() as c:
        c.execute("DELETE FROM template_files WHERE template = ?", (t["id"],))
        c.executemany("INSERT INTO template_files (template, path, data, mode, updated) VALUES (?, ?, ?, ?, ?)",
                      [(t["id"], p, d, m, now()) for p, d, m in clean])
        touch_template(c, t["id"])
    return template_view(name)


def rename_template(name, new):
    t = need_template(name)
    if not TEMPLATE_NAME.fullmatch(new or ""):
        raise ValueError("a template name is letters, digits, . _ or -")
    if new != name and template_row(new):
        raise ValueError(f"there is already a template named {new}")
    with db() as c:
        c.execute("UPDATE templates SET name = ?, updated = ? WHERE id = ?", (new, now(), t["id"]))


def delete_template(name):
    with db() as c:
        c.execute("DELETE FROM templates WHERE name = ?", (name,))


def template_view(name, with_data=False):
    t = need_template(name)
    files = template_files(name, with_data=True)
    out = {"name": t["name"], "description": t["description"], "updated": t["updated"], "hash": template_hash(files)}
    out["files"] = [{"path": f["path"], "mode": f["mode"], "size": f["size"],
                     **({"data": base64.b64encode(f["data"]).decode()} if with_data else {})} for f in files]
    return out


def template_archive(name):
    need_template(name)
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for f in template_files(name, with_data=True):
            info = tarfile.TarInfo(f"{name}/{f['path']}")
            info.size, info.mode, info.mtime = len(f["data"]), f["mode"], time.time()
            tar.addfile(info, io.BytesIO(f["data"]))
    return buffer.getvalue()


def is_text(data):
    if b"\0" in data[:8192]:
        return False
    try:
        data.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def size_text(n):
    for unit in ("B", "KB", "MB"):
        if n < 1024 or unit == "MB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


FILE_ICON = _SVG.format('<path d="M9 1.8H4.2a1 1 0 0 0-1 1v10.4a1 1 0 0 0 1 1h7.6a1 1 0 0 0 1-1V5.6z"/><path d="M9 1.8v3.8h3.8"/>')
FOLDER_ICON = _SVG.format('<path d="M1.8 4.2a1 1 0 0 1 1-1h3.4l1.4 1.6h5.6a1 1 0 0 1 1 1v6.9a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z"/>')

TEMPLATE_STYLE = """
.tree .it { padding-top: 7px; padding-bottom: 7px; min-height: 36px; box-sizing: border-box; }
.tree .reveal-hover { opacity: 0; transition: opacity .15s ease; } .tree .it:hover .reveal-hover, .tree .it:focus-within .reveal-hover { opacity: 1; }
.tree .it .ttl { font-weight: normal; }
.tree .it.dir .ttl { color: var(--mute); }
.tree .it.dir > .ic { color: var(--accent-ink); }
.editor { width: 100%; min-height: 62vh; box-sizing: border-box; font-family: var(--site-font-mono, ui-monospace, monospace);
  font-size: 13px; line-height: 1.55; tab-size: 4; white-space: pre; resize: vertical; margin: 0; }
.crumbpath { font-family: var(--site-font-mono, ui-monospace, monospace); font-size: var(--site-font-small); color: var(--mute); }
.crumbpath b { color: var(--fg); font-weight: normal; }
.upload { display: flex; gap: var(--s2); align-items: center; flex-wrap: wrap; }
.upload input[type=file] { font-size: var(--site-font-small); height: auto; padding: 5px; max-width: 280px; }
"""

EDITOR_SCRIPT = """<script>
document.querySelectorAll('textarea.editor').forEach(t => t.addEventListener('keydown', ev => {
  if (ev.key === 'Tab' && !ev.shiftKey) { ev.preventDefault(); const s = t.selectionStart;
    t.setRangeText('  ', s, t.selectionEnd, 'end'); }
  if ((ev.ctrlKey || ev.metaKey) && ev.key === 's') { ev.preventDefault(); t.form.requestSubmit(); }
}));
</script>"""


def turl(name, rest=""):
    return f"/templates/{quote(name)}{rest}"


def tpage(title, body, name, here):
    return page(title, body, name, here, "templates").replace("</style>", TEMPLATE_STYLE + "</style>", 1)


def templates_page(name, query):
    every = templates_all()
    needle = (query.get("q") or [""])[0].strip().lower()
    shown = [t for t in every if not needle or needle in (t["name"] + " " + t["description"]).lower()]
    band = site_ui.band("Templates", "box", summary=e(f"{len(every)} templates"))
    bar = (f'<div class=tb><form method=get class=joined><input name=q value="{e(needle)}" placeholder="Search templates…">'
           f'<button class=ghost>{site_ui.icon("search")}</button></form>{btn("/templates/new", "New template", "plus", primary=True)}</div>')
    rows = []
    for i, t in enumerate(shown):
        sub = f'{t["files"]} files · {size_text(t["size"])} · updated {e(ago(t["updated"]))}'
        desc = "files every template shares" if t["name"] == "common" else t["description"]
        rows.append(f'<div class=it style="--i:{i}"><span class=ic>{site_ui.icon("box")}</span><div class=main>'
                    f'<a class=ttl href="{turl(t["name"])}">{e(t["name"])}</a>'
                    f'{f"<span class=desc>{e(desc)}</span>" if desc else ""}<div class=sub>{sub}</div></div>'
                    f'<div class=aside>{btn(turl(t["name"], ".tar.gz"), "", "download", small=True)}</div></div>')
    listing = f'<div class=list>{"".join(rows)}</div>' if rows else \
        '<div class=empty-it>No templates yet. Push the ones you have with <code>wing template push --all</code>, or make one.</div>'
    return tpage("templates", band + bar + listing, name, "/templates")


def new_template_page(name):
    band = site_ui.band("New template", "plus", crumbs=[("/templates", "templates")])
    fields = (field("Name", '<input name=name required pattern="[A-Za-z0-9._-]+" autofocus placeholder="e.g. rust-cli">')
              + field("Description", "<input name=description>"))
    note = '<p class=mute style="margin:0">It starts with a <code>template.lua</code>; add <code>base/</code> files after.</p>'
    return tpage("new template", band + f'<div class=cols><div>{box("Template", note + "<br>" + form("/templates", fields, "Create"), "box")}</div></div>',
                 name, "/templates/new")


def template_band(t, view, files):
    base = turl(t["name"])
    tabs = [(base, "Files", "box", len(files), None, view == "files"),
            (base + "?v=settings", "Settings", "settings", None, None, view == "settings")]
    head = (f'<div class=head><div class=title>{site_ui.icon("box")}<a href="/templates">templates</a> <span class=sep>/</span> '
            f'<a href="{base}">{e(t["name"])}</a></div><div class=summary>'
            f'<span class=chip>{size_text(sum(f["size"] for f in files))}</span>'
            f'{btn(base + ".tar.gz", "Download", "download", small=True)}</div></div>')
    return f'<div class=band>{head}{site_ui.tabs(tabs)}</div>'


def tree_rows(name, files):
    rows, seen = [], set()
    for i, f in enumerate(files):
        parts = f["path"].split("/")
        for depth in range(1, len(parts)):
            folder = "/".join(parts[:depth])
            if folder not in seen:
                seen.add(folder)
                remove = (f'<form method=post action="{turl(name, "/f/" + quote(folder))}"><button class="ghost small" name=delete value=1 '
                          f'onclick="return confirm({e(json.dumps(f"Delete {folder}/ and everything in it?"))})">Delete</button></form>')
                rows.append(f'<div class="it dir" style="padding-left:calc(var(--s4) + {(depth - 1) * 18}px)">'
                            f'<span class=ic>{FOLDER_ICON}</span><div class=main><span class=ttl>{e(parts[depth - 1])}/</span></div>'
                            f'<div class="aside reveal-hover">{remove}</div></div>')
        indent = (len(parts) - 1) * 18
        aside = f'<span class=hide-sm>{size_text(f["size"])}</span>' + (' <span class=chip>exec</span>' if f["mode"] & 0o111 else "")
        rows.append(f'<div class=it style="padding-left:calc(var(--s4) + {indent}px)"><span class=ic>{FILE_ICON}</span><div class=main>'
                    f'<a class=ttl href="{turl(name, "/f/" + quote(f["path"]))}">{e(parts[-1])}</a></div><div class=aside>{aside}</div></div>')
    return rows


def template_page(name, tname, query):
    t = template_row(tname)
    if not t:
        return None
    files = template_files(tname)
    base = turl(tname)
    if (query.get("v") or [""])[0] == "settings":
        fields = (field("Name", f'<input name=rename value="{e(t["name"])}" required pattern="[A-Za-z0-9._-]+">')
                  + '<p class=mute style="margin:0">The description comes from <code>template.lua</code>.</p>')
        main = box("Settings", form(base, fields, delete=f'Delete the template {tname} and all its files?'), "settings")
        return tpage(f"settings · {tname}", template_band(t, "settings", files) + f'<div class=cols><div>{main}</div></div>', name, base + "?v=settings")
    add = (f'<form method=post action="{base}/new" class=joined><input name=path placeholder="New file — base/src/main.rs, flavours/uv/pyproject.toml" '
           f'required autocomplete=off><button>{site_ui.icon("plus")}New file</button></form>')
    upload = (f'<form method=post action="{base}/upload" enctype="multipart/form-data" class=upload>'
              f'<input name=dir placeholder="into folder, e.g. base" style="height:var(--h);width:170px;margin:0;font-size:var(--site-font-small)">'
              f'<input type=file name=files multiple required><button class=ghost>{site_ui.icon("download")}Upload</button></form>')
    about = t["description"] or ("files every template shares" if tname == "common" else "")
    head = f'<p class=mute style="margin:0 0 var(--s4)">{e(about)}</p>' if about else ""
    body = (template_band(t, "files", files) + head + f'<div class=tb>{add}</div><div class=tb>{upload}</div>'
            + f'<div class="box tree">{items(tree_rows(tname, files), "no files yet")}</div>')
    return tpage(tname, body, name, base)


def template_file_page(name, tname, path):
    t = template_row(tname)
    f = template_file(tname, path) if t else None
    if not f:
        return None
    files = template_files(tname)
    base = turl(tname)
    here = turl(tname, "/f/" + quote(path))
    crumbs = " / ".join(e(p) for p in path.split("/")[:-1])
    title = (f'<div class=title-row><div class=crumbpath>{crumbs + " / " if crumbs else ""}<b>{e(path.split("/")[-1])}</b></div>'
             f'<span class=end>{btn(here + "?raw=1", "Raw", "download", small=True)}{btn(base, "All files", "box", small=True)}</span></div>')
    executable = " checked" if f["mode"] & 0o111 else ""
    path_input = f'<input name=rename value="{e(path)}" required>'
    common = (f'<div class=two>{field("Path", path_input)}'
              f'<label>Executable<span style="display:flex;align-items:center;gap:8px;height:var(--h)">'
              f'<input type=checkbox name=exec value=1{executable} style="width:auto"> run as a program</span></label></div>')
    if is_text(f["data"]):
        editor = f'<textarea class=editor name=content spellcheck=false>{e(f["data"].decode())}</textarea>'
        body = form(here, editor + common, "Save", delete=f"Delete {path}?")
    else:
        body = (f'<p>A binary file of {size_text(len(f["data"]))}; download it with Raw, or replace it with an upload.</p>'
                + form(here, common, "Save", delete=f"Delete {path}?"))
    meta = f'<div class=meta-row><span>{size_text(len(f["data"]))} · updated {e(ago(f["updated"]))} · Ctrl+S saves</span></div>'
    return tpage(f"{path} · {tname}", template_band(t, "files", files) + title + meta + box("", body) + EDITOR_SCRIPT, name, here)


def parse_upload(headers, body):
    """The files of a multipart form, as (name, filename, bytes), and its plain fields."""
    message = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
        b"Content-Type: " + headers.get("Content-Type", "").encode() + b"\r\n\r\n" + body)
    files, fields = [], {}
    for part in message.iter_parts():
        filename = part.get_filename()
        payload = part.get_payload(decode=True) or b""
        if filename:
            files.append((part.get_param("name", header="content-disposition"), filename, payload))
        else:
            fields[part.get_param("name", header="content-disposition")] = payload.decode(errors="replace")
    return files, fields


# --- Requests. ------------------------------------------------------------------------

def segments(path):
    return [p for p in urlparse(path).path.split("/") if p]


class Handler(BaseHTTPRequestHandler):
    server_version = "wing"

    def reply(self, code, body, kind="text/html; charset=utf-8", headers=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def json(self, code, value):
        self.reply(code, json.dumps(value, indent=1), "application/json")

    def go(self, where):
        self.reply(303, "", headers=[("Location", where if where.startswith("/") and not where.startswith("//") else "/")])

    def raw_body(self):
        size = int(self.headers.get("Content-Length") or 0)
        if size > 64 << 20:
            raise ValueError("a request is at most 64 MB")
        return self.rfile.read(size)

    def body(self):
        return self.raw_body().decode(errors="replace")

    def handle_any(self):
        try:
            if self.path.startswith("/api/"):
                return self.api()
            if self.command in ("GET", "HEAD"):
                return self.get()
            if self.command == "POST":
                return self.post()
            self.reply(405, "method not allowed", "text/plain")
        except Exception as error:
            traceback.print_exception(error)
            self.reply(500, page("error", '<div class=empty>Something went wrong drawing this page.</div>', None, "/"))

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = handle_any

    def get(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        name = self.headers.get("X-Forwarded-Preferred-Username")
        parts = segments(self.path)
        out = None
        if not parts:
            out = projects_page(name, query)
        elif parts == ["new"]:
            out = new_project_page(name)
        elif parts == ["import"]:
            out = import_page(name)
        elif parts == ["tasks"]:
            out = all_tasks_page(name, query)
        elif parts == ["settings"]:
            out = settings_page(name)
        elif parts == ["templates"]:
            out = templates_page(name, query)
        elif parts == ["templates", "new"]:
            out = new_template_page(name)
        elif parts[0] == "templates" and len(parts) == 2 and parts[1].endswith(".tar.gz"):
            tname = parts[1][:-len(".tar.gz")]
            if not template_row(tname):
                return self.reply(404, "no such template", "text/plain")
            return self.reply(200, template_archive(tname), "application/gzip",
                              [("Content-Disposition", f'attachment; filename="{tname}.tar.gz"')])
        elif parts[0] == "templates" and len(parts) == 2:
            out = template_page(name, parts[1], query)
        elif parts[0] == "templates" and len(parts) >= 4 and parts[2] == "f":
            path = "/".join(parts[3:])
            if query.get("raw"):
                f = template_file(parts[1], path)
                if not f:
                    return self.reply(404, "no such file", "text/plain")
                kind = "text/plain; charset=utf-8" if is_text(f["data"]) else "application/octet-stream"
                return self.reply(200, f["data"], kind, [("Content-Disposition", f'inline; filename="{path.split("/")[-1]}"')])
            out = template_file_page(name, parts[1], path)
        elif parts == ["favicon.svg"]:
            return self.reply(200, site_ui.logo(), "image/svg+xml")
        elif parts == ["healthz"]:
            return self.reply(200, "ok", "text/plain")
        elif parts[0] == "p" and len(parts) >= 2:
            rest = parts[2:]
            if not rest:
                out = project_page(name, parts[1], query)
            elif rest == ["plans"]:
                out = plans_page(name, parts[1], query)
            elif len(rest) == 2 and rest[0] == "t" and rest[1].isdigit():
                out = task_page(name, parts[1], rest[1])
            elif len(rest) == 2 and rest[0] == "plans" and rest[1].isdigit():
                out = plan_page(name, parts[1], rest[1], query)
        if out is None:
            return self.reply(404, page("not found", '<div class=empty>Nothing here.</div>', name, url.path))
        self.reply(200, out)

    def post(self):
        # Forms come only from this site's own pages.
        origin = self.headers.get("Origin")
        if origin and urlsplit(origin).hostname not in (DOMAIN, "127.0.0.1", "localhost"):
            return self.reply(403, "cross-site form refused", "text/plain")
        name = self.headers.get("X-Forwarded-Preferred-Username")
        parts = segments(self.path)
        body = self.raw_body()
        try:
            if len(parts) == 3 and parts[0] == "templates" and parts[2] == "upload":
                files, fields = parse_upload(self.headers, body)
                folder = fields.get("dir", "").strip().strip("/")
                for _, filename, data in files:
                    save_template_file(parts[1], f"{folder}/{filename}" if folder else filename, data)
                return self.go(turl(parts[1]))
        except (ValueError, LookupError) as error:
            return self.reply(400, page("error", f'<div class=flash>{e(str(error))}</div>', name, "/"))
        raw = parse_qs(body.decode(errors="replace"), keep_blank_values=True)
        form_data = {k: v[-1] for k, v in raw.items()}
        back = form_data.pop("back", "")
        f = form_data
        try:
            if parts == ["templates"]:
                if f.get("name") == "new":
                    raise ValueError("new is taken by the page that makes templates")
                return self.go(turl(create_template(f.get("name", "").strip(), f.get("description", "").strip())["name"]))
            if parts[:1] == ["templates"] and len(parts) == 2:
                if f.get("delete"):
                    delete_template(parts[1])
                    return self.go("/templates")
                new = f.get("rename", "").strip()
                if new == "new":
                    raise ValueError("new is taken by the page that makes templates")
                rename_template(parts[1], new)
                return self.go(turl(new, "?v=settings"))
            if len(parts) == 3 and parts[0] == "templates" and parts[2] == "new":
                path = clean_path(f.get("path", ""))
                if template_file(parts[1], path):
                    raise ValueError(f"{path} already exists")
                save_template_file(parts[1], path, b"")
                return self.go(turl(parts[1], "/f/" + quote(path)))
            if len(parts) >= 4 and parts[0] == "templates" and parts[2] == "f":
                path = "/".join(parts[3:])
                old = template_file(parts[1], path)
                if f.get("delete"):
                    delete_template_file(parts[1], path)
                    return self.go(turl(parts[1]))
                if not old:
                    raise LookupError("no such file")
                data = f["content"].replace("\r\n", "\n").encode() if "content" in f else old["data"]
                mode = (old["mode"] | 0o111) if f.get("exec") else (old["mode"] & ~0o111)
                target = save_template_file(parts[1], path, data, mode, f.get("rename", "").strip() or None)
                return self.go(turl(parts[1], "/f/" + quote(target)))
            if parts == ["projects"]:
                remote = f.pop("remote", "").strip()
                if remote:
                    f["remotes"] = [{"name": "origin", "url": remote}]
                return self.go(purl(save_project(f)["name"]))
            if parts == ["import"]:
                import_from_gitea(raw.get("repo", []))
                return self.go("/")
            if parts == ["tasks"]:
                pname = f.pop("project", "")
                save_task(pname, quick_text(f.pop("quick", ""), {k: v for k, v in f.items() if v}))
                return self.go(back or "/tasks")
            if parts == ["settings"]:
                if f.get("revoke"):
                    with db() as c:
                        c.execute("DELETE FROM tokens WHERE id = ?", (int(f["revoke"]),))
                    return self.go("/settings")
                return self.reply(200, settings_page(name, make_token(f.get("token", ""))))
            if parts[:1] == ["p"] and len(parts) >= 2:
                pname, rest = parts[1], parts[2:]
                base = purl(pname)
                if not rest:
                    if f.get("delete"):
                        delete_project(pname)
                        return self.go("/")
                    remotes = [line.split(None, 1) for line in f.pop("remotes", "").splitlines() if line.strip()]
                    f["remotes"] = [{"name": r[0], "url": r[1]} if len(r) == 2 else {"name": "origin", "url": r[0]} for r in remotes]
                    f["tags"] = [t.strip() for t in f.get("tags", "").split(",") if t.strip()]
                    save_project({**f, "name": pname})
                    return self.go(base + "?v=edit")
                if rest == ["tasks"]:
                    save_task(pname, quick_text(f.pop("quick", ""), {k: v for k, v in f.items() if v}))
                    return self.go(back or base)
                if len(rest) == 2 and rest[0] == "t":
                    if f.get("delete"):
                        delete_task(pname, rest[1])
                        return self.go(base)
                    if "priority" in f:
                        f["priority"] = int(f["priority"])
                    save_task(pname, f, rest[1])
                    return self.go(back or f"{base}/t/{rest[1]}")
                if rest == ["plans"]:
                    return self.go(f"{base}/plans/{save_plan(pname, f)['number']}")
                if len(rest) == 2 and rest[0] == "plans":
                    if f.get("delete"):
                        delete_plan(pname, rest[1])
                        return self.go(base + "/plans")
                    save_plan(pname, f, rest[1])
                    return self.go(f"{base}/plans/{rest[1]}")
        except (ValueError, LookupError) as error:
            return self.reply(400, page("error", f'<div class=flash>{e(str(error).strip("'"))}</div>'
                                        f'<p><a href="javascript:history.back()">back</a></p>', name, "/"))
        self.reply(404, "not found", "text/plain")

    # The CLI's JSON interface, with a token from the settings page.
    def api(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or not check_token(auth[7:].strip()):
            return self.json(401, {"error": "a token from the settings page is needed"})
        query = {k: v[-1] for k, v in parse_qs(urlparse(self.path).query).items()}
        try:
            data = json.loads(self.body() or "{}") if self.command in ("POST", "PATCH", "PUT") else {}
            if not isinstance(data, dict):
                raise ValueError("send a JSON object")
            return self.json(*api_route(self.command, segments(self.path)[1:], query, data))
        except LookupError as error:
            return self.json(404, {"error": str(error).strip("'\"")})
        except (ValueError, TypeError) as error:
            return self.json(400, {"error": str(error)})

    def log_message(self, *args):
        pass


def api_route(method, parts, query, data):
    """/tasks, /projects[/<name>[/tasks[/<n>] | /plans[/<n>]]]"""
    if parts == ["tasks"] and method == "GET":
        return 200, tasks(state=query.get("state"))
    if parts == ["templates"] and method == "GET":
        return 200, [{k: v for k, v in template_view(t["name"]).items() if k != "files"} | {"files": t["files"]}
                     for t in templates_all()]
    if len(parts) == 2 and parts[0] == "templates":
        if method == "GET":
            return 200, template_view(parts[1], with_data=True)
        if method == "PUT":
            files = data.get("files")
            if not isinstance(files, list):
                raise ValueError("send the template's files as a list")
            return 200, {k: v for k, v in replace_template(parts[1], files).items() if k != "files"}
        if method == "DELETE":
            need_template(parts[1])
            delete_template(parts[1])
            return 200, {"deleted": parts[1]}
    if parts == ["projects"]:
        if method == "GET":
            return 200, projects()
        if method == "POST":
            return 200, save_project(data)
    if len(parts) < 2 or parts[0] != "projects":
        raise LookupError("no such route")
    pname, rest = parts[1], parts[2:]
    if not rest:
        if method in ("PATCH", "PUT"):
            return 200, save_project({**data, "name": pname})
        p = need_project(pname)
        if method == "GET":
            return 200, {**p, **summary(p), "tasks": tasks(pname), "plans": plans(pname)}
        if method == "DELETE":
            delete_project(pname)
            return 200, {"deleted": pname}
    need_project(pname)
    if rest == ["tasks"]:
        if method == "GET":
            return 200, tasks(pname, plan=query.get("plan"), state=query.get("state"))
        if method == "POST":
            return 201, save_task(pname, quick_text(data.pop("quick"), data) if "quick" in data else data)
    if len(rest) == 2 and rest[0] == "tasks" and rest[1].isdigit():
        if method == "GET":
            t = task(pname, rest[1])
            if not t:
                raise LookupError("no such task")
            return 200, t
        if method in ("PATCH", "PUT"):
            return 200, save_task(pname, data, rest[1])
        if method == "DELETE":
            delete_task(pname, rest[1])
            return 200, {"deleted": int(rest[1])}
    if rest == ["plans"]:
        if method == "GET":
            return 200, plans(pname)
        if method == "POST":
            return 201, save_plan(pname, data)
    if len(rest) == 2 and rest[0] == "plans" and rest[1].isdigit():
        if method == "GET":
            l = plan(pname, rest[1])
            if not l:
                raise LookupError("no such plan")
            return 200, {**l, "tasks": tasks(pname, plan=rest[1])}
        if method in ("PATCH", "PUT"):
            return 200, save_plan(pname, data, rest[1])
        if method == "DELETE":
            delete_plan(pname, rest[1])
            return 200, {"deleted": int(rest[1])}
    raise LookupError("no such route")


if __name__ == "__main__":
    initialize()
    host, port = LISTEN.rsplit(":", 1)
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()
