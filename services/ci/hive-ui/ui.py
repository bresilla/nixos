"""The original Hive pages backed by Muros and the trusted login proxy."""
import site_ui
import base64
import html
import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import subprocess
import threading
import time
import urllib.parse
import uuid
from http.cookies import SimpleCookie
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote

import backend
import repo_rules
import sys
from backend import frontend_api as service_api, load, save, load_repos, save_repos

SECRETS = os.environ.get("CI_SECRETS", "/var/lib/ci/secrets")
CHECK_KEY = os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", "/run/credentials/muros-ui.service"), "builder-key")
COOKIE = "__Host-muros-ui" if backend.ORIGIN.startswith("https:") else "muros_ui"
CSRF_KEY = secrets.token_bytes(32)
SYSTEMS = os.environ.get("CI_SYSTEMS", "").split()
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
SYSTEM = re.compile(r"[a-z0-9_]+-[a-z]+")
ADDRESS = re.compile(r"[A-Za-z0-9.:-]{1,253}")
HOST_KEY = re.compile(r"ssh-(ed25519|rsa) [A-Za-z0-9+/=]{20,800}")
FEATURES = re.compile(r"[a-z0-9,-]{0,200}")
SEGMENT = re.compile(r"[A-Za-z0-9._-]{1,100}")
GIT_URL = re.compile(r"(https?://|ssh://)[A-Za-z0-9._~:@%/+-]{3,300}|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._~/+-]{1,300}")
BRANCH = re.compile(r"[A-Za-z0-9._/-]{1,100}")
SIGN_OUT = site_ui.SIGN_OUT
ADMINS_ONLY = "only build admins on id.bresilla.com may do that"
# Who is looking at the page being made, admin or not; nobody when signed out.
VIEW = threading.local()
# Settings fields: file name and label.
FIELDS = [
    ("attic-token", "attic token that may push to every cache"),
    ("pin-token", "pin token of cache.bresilla.com"),
]
results = {}
lock = threading.Lock()

STYLE = site_ui.STYLE + (Path(os.environ["CI_STYLE"]).read_text() if "CI_STYLE" in os.environ else "")

SCRIPT = site_ui.SCRIPT

ICONS = site_ui.ICONS


logo = site_ui.logo


def e(s):
    return html.escape(str(s), quote=True)


def when(stamp):
    if not stamp:
        return "—"
    try:
        t = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
    except ValueError:
        return str(stamp)
    ago = (datetime.now(timezone.utc) - t).total_seconds()
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if ago >= n:
            return f"{int(ago // n)}{unit} ago"
    return "just now"


def stamp(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0


def seconds(start, end):
    if not start or not end or not stamp(start) or not stamp(end):
        return None
    return stamp(end) - stamp(start)


def took(start, end):
    s = seconds(start, end)
    if s is None:
        return ""
    return f"{int(s // 60)}m {int(s % 60)}s" if s >= 60 else f"{int(s)}s"


# Build states as the shared pills and dots: ok, warn (still going), fail, none.
STATES = {"succeeded": "ok", "failed": "fail", "cancelled": "none", "skipped": "none"}


def state_of(status):
    return STATES.get(status, "warn")


def status_pill(status):
    return site_ui.pill(state_of(status), status)


def repo_path(forge, owner, name):
    return f"/api/repos/{forge}/{quote(owner)}/{quote(name)}"


def page_url(forge, owner, name=None):
    base = f"/-/repo/{forge}/{quote(owner)}"
    return f"{base}/{quote(name)}" if name else base


def store_url(m):
    if not m.get("hostKey"):
        raise ValueError("fetch the machine's host key first")
    url = f"ssh-ng://{m['user']}@{m['address']}?ssh-key={CHECK_KEY}"
    if m.get("hostKey"):
        url += "&base64-ssh-public-host-key=" + base64.b64encode(m["hostKey"].encode()).decode()
    return url


def run_check(key, argv, ok):
    with lock:
        results[key] = ("running", time.strftime("%H:%M:%S"))
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=300)
        text = ok(out.stdout.strip()) if out.returncode == 0 else "failed: " + (out.stderr.strip().splitlines() or ["?"])[-1]
    except subprocess.TimeoutExpired:
        text = "failed: no answer in 5 minutes"
    except (OSError, ValueError, IndexError) as err:
        text = f"failed: {err}"
    with lock:
        results[key] = (text, time.strftime("%H:%M:%S"))


def check_machine(name, m):
    argv = ["nix", "--extra-experimental-features", "nix-command", "store", "info", "--store", store_url(m)]
    threading.Thread(target=run_check, args=("machine:" + name, argv, lambda _: "reachable"), daemon=True).start()


def test_system(system):
    state = load()
    machine = state["machines"].get(state["systems"].get(system))
    if not machine or not machine["enabled"] or not machine["hostKey"]:
        raise ValueError("assign an enabled machine and fetch its host key first")
    host_key = base64.b64encode(machine["hostKey"].encode()).decode()
    builder = (f"ssh-ng://{machine['user']}@{machine['address']} {system} {CHECK_KEY} "
               f"{machine['jobs']} {machine['speed']} {machine['features'] or '-'} - {host_key}")
    expr = ('derivation { name = "ci-check"; system = "%s"; builder = "/bin/sh"; t = builtins.currentTime;'
            ' args = [ "-c" "n=0; while read -r l; do case $l in processor*) n=$((n+1));; esac;'
            ' done </proc/cpuinfo; echo $n >$out" ]; }') % system
    expr = expr.replace('name = "ci-check"', f'name = "ci-check-{uuid.uuid4().hex}"')
    argv = ["nix", "--extra-experimental-features", "nix-command", "build", "--impure", "--no-link",
            "--max-jobs", "0", "--builders", builder, "--print-out-paths", "--expr", expr]

    def ok(path):
        with open(path.splitlines()[-1]) as f:
            return f"built on a {f.read().strip()}-cpu machine"
    threading.Thread(target=run_check, args=("system:" + system, argv, ok), daemon=True).start()


def fetch_host_key(address):
    out = subprocess.run(["ssh-keyscan", "-t", "ed25519", "-T", "10", address],
                         capture_output=True, text=True, timeout=20)
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and not line.startswith("#"):
            return f"{parts[1]} {parts[2]}"
    return None


def check_result(key):
    with lock:
        text, at = results.get(key, ("", ""))
    if not text:
        return site_ui.pill("none", "not checked")
    if text.startswith("failed"):
        reason = text.removeprefix("failed").lstrip(": ")
        return f'{site_ui.pill("fail", "failed")} <span class=mute>{e(at)}</span><div class=reason>{e(reason)}</div>'
    return f'{site_ui.pill("warn" if text == "running" else "ok", text)} <span class=mute>{e(at)}</span>'


def check_state(key):
    with lock:
        text = results.get(key, ("", ""))[0]
    return None if not text else "warn" if text == "running" else "fail" if text.startswith("failed") else "ok"


# Secrets: one file each; touching "saved" reloads the daemon credentials.

def secret_value(name):
    try:
        with open(os.path.join(SECRETS, name)) as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


def save_secrets(values):
    for name, value in values.items():
        tmp = os.path.join(SECRETS, name + ".new")
        with open(tmp, "w") as f:
            f.write(value)
        os.chmod(tmp, 0o600)
        os.replace(tmp, os.path.join(SECRETS, name))
    with open(os.path.join(SECRETS, "saved"), "w") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S\n"))


def muros_state():
    out = subprocess.run(["systemctl", "is-active", "murosd.service"], capture_output=True, text=True)
    return out.stdout.strip() or "unknown"


# Pages, laid out as on the cache UI.

def layout(title, body, user, flash="", nav="repos", band=""):
    signed_in = [("builders", "/-/builders", "Builders"), ("settings", "/-/settings", "Settings")]
    links = [("repos", "/", "Repositories")] + (signed_in if user else [])
    # A page with a band shows its notice under the band, not above it.
    if band:
        body, flash = band + (f'<div class=flash>{e(flash)}</div>' if flash else "") + body, ""
    return site_ui.page(site="build", title=title, body=body, links=links, active=nav,
                        name=getattr(VIEW, "name", None), here=getattr(VIEW, "path", "/"),
                        flash=flash, style=STYLE, script=SCRIPT)


def post_button(action, label, cls="ghost small", confirm=""):
    check = f' onsubmit="return confirm(\'{e(confirm)}\')"' if confirm else ""
    return f'<form class=inline method=post action="{e(action)}"{check}><button class="{cls}">{e(label)}</button></form>'


def pills(*parts):
    return "".join(site_ui.pill(state, text) for state, text in parts if text)


def plural(n, word, many=None):
    return f"{n} {word if n == 1 else many or word + 's'}"


def repo_builds(user, r):
    """The repository's builds, newest first; none asked for while it is off."""
    if not r["enabled"]:
        return []
    page = service_api("GET", repo_path(r["forge"], r["owner"], r["name"]) + "/builds?page=1", user) or {}
    return page.get("items") or []


def repo_list(user, forge=None, owner=None):
    """(repository, builds) for every repository, or for one owner's."""
    repos = [r for r in service_api("GET", "/api/repos", user) or []
             if (forge is None or r["forge"] == forge) and (owner is None or r["owner"] == owner)]
    repos.sort(key=lambda r: (r["owner"].lower(), not r["enabled"], r["name"].lower()))
    return [(r, repo_builds(user, r)) for r in repos]


def repo_state(r, items):
    return state_of(items[0]["status"]) if r["enabled"] and items else "none"


def tally(entries):
    """Pills: how many of these repositories failed, are building, pass, or are idle."""
    n = {"fail": 0, "warn": 0, "ok": 0, "none": 0}
    for r, items in entries:
        n[repo_state(r, items)] += 1
    return pills(*((s, f"{n[s]} {word}" if n[s] else "") for s, word in
                   (("fail", "failed"), ("warn", "building"), ("ok", "ok"), ("none", "idle"))))


def add_form():
    """Adding a repository, folded into a button; admins only."""
    form = ('<p class=mute>Any git URL this server can fetch. Its <code>flake.nix</code> is built from the '
            '<code>checks</code> output, for every system it lists; new commits on the branch are picked up within '
            'the interval.</p><form method=post action="/-/repos/add" class=fields>'
            '<label for=add-url>git URL</label><input id=add-url name=url required '
            'placeholder="https://git.bresilla.com/bresilla/termworks">'
            '<label for=add-branch>branch</label><input id=add-branch name=branch value=main>'
            '<label for=add-interval>check every</label><input id=add-interval name=interval value=60 '
            'title="seconds between checks, 30 to 86400">'
            '<span></span><button>Add repository</button></form>')
    return site_ui.reveal("Add repository", form)


def recent_table(entries, limit=10, owner=True):
    """The newest builds of these repositories as a table; owner=False names them without it."""
    found = [(r, b) for r, items in entries for b in items[:limit]]
    found.sort(key=lambda rb: stamp(rb[1]["created_at"]), reverse=True)
    rows = []
    for r, b in found[:limit]:
        url = page_url(r["forge"], r["owner"], r["name"])
        target = f"PR #{b['pr_number']}" if b.get("pr_number") else b["branch"]
        label = f'{r["owner"]}/{r["name"]}' if owner else r["name"]
        rows.append([f'<a href="{e(url)}">{e(label)}</a>', f'<a href="{e(url)}/{b["number"]}">#{b["number"]}</a>',
                     status_pill(b["status"]), e(target), f'<span class=mute>{e(when(b["created_at"]))}</span>',
                     e(took(b["started_at"], b["finished_at"]))])
    return site_ui.table(["repository", "build", "status", "for", "started", "took"], rows, numeric=(5,))


def repos_page(user, flash):
    entries = repo_list(user)
    owners = {}
    for r, items in entries:
        owners.setdefault((r["forge"], r["owner"]), []).append((r, items))
    tiles = ""
    for (forge, owner), group in owners.items():
        newest = max((items[0]["created_at"] for r, items in group if items), key=stamp, default=None)
        off = sum(1 for r, _ in group if not r["enabled"])
        rows = [("repositories", e(len(group)) + (f' <span class=mute>· {off} off</span>' if off else "")),
                ("latest build", e(when(newest)) if newest else '<span class=mute>none yet</span>')]
        state = site_ui.worst(repo_state(r, items) for r, items in group)
        tiles += site_ui.tile(owner, rows, state, href=page_url(forge, owner), foot=tally(group))
    summary = pills(("", plural(len(owners), "owner")), ("", plural(len(entries), "repository", "repositories")))
    band = site_ui.band("Repositories", "overview", summary=summary + tally(entries))
    body = (add_form() if user else "") + (f'<div class=grid>{tiles}</div>' if tiles else
                                           '<div class="card empty">no repositories yet</div>')
    if entries:
        body += site_ui.section("Recent builds", recent_table(entries), note="across every repository")
    return layout("repositories", body, user, flash, "repos", band)


def repo_tile(r, items):
    url = page_url(r["forge"], r["owner"], r["name"])
    b = items[0] if items else None
    note = (site_ui.pill("none", "private") if r.get("private") else "") + ("" if r["enabled"] else site_ui.pill("none", "off"))
    if b:
        rows = [("latest", f'{status_pill(b["status"])} <span class=mute>#{b["number"]}</span>'),
                ("branch", e(b["branch"])), ("started", e(when(b["created_at"]))),
                ("took", e(took(b["started_at"], b["finished_at"]) or "—"))]
    else:
        rows = [("latest", '<span class=mute>' + ("off: no builds" if not r["enabled"] else "no builds yet") + '</span>'),
                ("branch", e(r["default_branch"]))]
    return site_ui.tile(r["name"], rows, repo_state(r, items), href=url, note=note)


def owner_page(user, forge, owner, flash):
    entries = repo_list(user, forge, owner)
    if len(entries) > 12:
        rows = []
        for r, items in entries:
            b = items[0] if items else None
            url = page_url(forge, owner, r["name"])
            rows.append([f'<span class=nowrap>{site_ui.dot(repo_state(r, items))}<a href="{e(url)}">{e(r["name"])}</a></span>',
                         status_pill(b["status"]) if b else site_ui.pill("none", "off" if not r["enabled"] else "no builds"),
                         f'<a href="{e(url)}/{b["number"]}">#{b["number"]}</a>' if b else "",
                         e(b["branch"] if b else r["default_branch"]),
                         f'<span class=mute>{e(when(b["created_at"]))}</span>' if b else "",
                         e(took(b["started_at"], b["finished_at"])) if b else ""])
        repos = site_ui.section("Repositories", site_ui.table(
            ["repository", "status", "build", "branch", "started", "took"], rows, numeric=(5,)))
    elif entries:
        repos = '<div class=grid>' + "".join(repo_tile(r, items) for r, items in entries) + '</div>'
    else:
        repos = '<div class="card empty">no repositories for this owner</div>'
    summary = pills(("", plural(len(entries), "repository", "repositories"))) + tally(entries)
    band = site_ui.band(owner, "org", crumbs=[("/", "Repositories")], summary=summary)
    body = (add_form() if user else "") + repos
    if any(items for _, items in entries):
        body += site_ui.section("Recent builds", recent_table(entries, owner=False), note=f"across {owner}'s repositories")
    return layout(owner, body, user, flash, "repos", band)


def repo_band(user, forge, owner, name, tab, *, title=None, ico="repo", crumbs=(), summary="", small="", count=None, state=None):
    """The band every page of a repository starts with: breadcrumbs, a title, and its tabs."""
    base = page_url(forge, owner, name)
    trail = [("/", "Repositories"), (page_url(forge, owner), owner)] + list(crumbs)
    items = [(base, "Builds", "builds", count, state, tab == "builds")]
    if user:
        items.append((f"{base}/settings", "Rules", "settings", None, None, tab == "rules"))
    return site_ui.band(title or name, ico, crumbs=trail, summary=summary, items=items, small=small)


def repo_name(url):
    """owner/name from a git URL, as Muros lists pull-based repositories."""
    path = re.sub(r"^[a-z+]+://[^/]+/|^[^@/]+@[^:]+:", "", url).removesuffix("/").removesuffix(".git")
    parts = [p for p in path.split("/") if p]
    return "/".join(parts[-2:]) if len(parts) >= 2 else None


def repo_page(user, forge, owner, name, flash):
    base = page_url(forge, owner, name)
    repo = service_api("GET", repo_path(forge, owner, name), user) or {}
    page = service_api("GET", repo_path(forge, owner, name) + "/builds?page=1", user) or {}
    items = page.get("items") or []
    enabled = page.get("enabled", repo.get("enabled", True))
    rows = []
    for b in items:
        target = f"PR #{b['pr_number']}" if b.get("pr_number") else b["branch"]
        rows.append([f'<a href="{base}/{b["number"]}">#{b["number"]}</a>', status_pill(b["status"]), e(target),
                     f'<code>{e(b["commit_sha"][:10])}</code>', f'<span class=mute>{e(when(b["created_at"]))}</span>',
                     e(took(b["started_at"], b["finished_at"]))])
    table = site_ui.table(["build", "status", "for", "commit", "started", "took"], rows, numeric=(5,)) if rows \
        else '<div class=empty>no builds yet: push a commit</div>'
    latest = items[0] if items else None
    failed = sum(1 for b in items if state_of(b["status"]) == "fail")
    summary = ((status_pill(latest["status"]) if latest else "") + ("" if enabled else site_ui.pill("none", "off"))
               + (site_ui.pill("none", "private") if repo.get("private") else "")
               + (f'<code>{e(repo["url"])}</code>' if repo.get("url") else ""))
    band = repo_band(user, forge, owner, name, "builds", summary=summary, count=len(items) or None,
                     state="fail" if latest and state_of(latest["status"]) == "fail" else None)
    # A few facts first: the newest build, how the recent ones went, how long they take.
    recent = items[:20]
    durations = [seconds(b["started_at"], b["finished_at"]) for b in reversed(recent)]
    passed = sum(1 for b in recent if state_of(b["status"]) == "ok")
    broken = sum(1 for b in recent if state_of(b["status"]) == "fail")
    if latest:
        tiles = (site_ui.tile("Latest build", [
                    ("build", f'<a href="{base}/{latest["number"]}">#{latest["number"]}</a> {status_pill(latest["status"])}'),
                    ("branch", e(latest["branch"])), ("started", e(when(latest["created_at"])))], state_of(latest["status"]))
                 + site_ui.tile(f"Last {plural(len(recent), 'build')}", [
                    ("passed", e(passed)), ("failed", e(broken)), ("other", e(len(recent) - passed - broken))],
                    "fail" if broken else "ok")
                 + site_ui.tile("Duration", [("last", e(took(latest["started_at"], latest["finished_at"]) or "—")),
                                             ("trend", site_ui.spark(durations))]))
    else:
        tiles = site_ui.tile("Repository", [("branch", e(repo.get("default_branch", ""))),
                                            ("checks", e(f'every {repo["poll_interval"]}s') if repo.get("poll_interval") else "—")])
    actions = ""
    if user:
        actions = ('<div class=actions>'
                   + (post_button(f"{base}/trigger", "Build now", "small") if enabled else "")
                   + post_button(f"{base}/toggle", "Disable" if enabled else "Enable", "ghost small" if enabled else "small")
                   + post_button(f"{base}/remove", "Remove", "danger small", f"Remove {owner}/{name}?") + '</div>')
    body = (f'{actions}<div class=grid>{tiles}</div>'
            + site_ui.section("Builds", table, note=plural(len(items), "build") + (f" · {failed} failed" if failed else "")))
    return layout(f"{owner}/{name}", body, user, flash, "repos", band)


def short_error(text, limit=240):
    """One line for the list: Nix's last error and its reason, not the whole build output."""
    lines = [line.strip() for line in str(text).splitlines() if line.strip()]
    if not lines:
        return ""
    found = [i for i, line in enumerate(lines) if line.lower().startswith("error:")]
    picked = lines[found[-1]:found[-1] + 2] if found else lines[-1:]
    message = " ".join(line for line in picked if line.lower().startswith(("error:", "reason:"))) or picked[0]
    return message if len(message) <= limit else message[:limit - 1] + "…"


def build_page(user, forge, owner, name, number, flash):
    base = page_url(forge, owner, name)
    detail = service_api("GET", repo_path(forge, owner, name) + f"/builds/{number}", user)
    b = detail["build"]
    actions = ""
    if user:
        actions = ('<div class=actions>' + post_button(f"{base}/{number}/restart", "Restart", "small")
                   + post_button(f"{base}/{number}/cancel", "Cancel", "danger small", "Cancel this build?") + '</div>')
    rows = []
    attrs = sorted(detail["attributes"], key=lambda a: (state_of(a["status"]) != "fail", a["status"] == "succeeded", a["attr"]))
    for a in attrs:
        log = f'<a href="{base}/{number}/log/{quote(a["attr"], safe="")}">log</a>'
        redo = post_button(f'{base}/{number}/attr/{quote(a["attr"], safe="")}/restart', "Restart") if user else ""
        cached = " <span class=mute>cached</span>" if a.get("cached") else ""
        error = f'<div class="mute attr-error" title="the full error is in the log">{e(short_error(a["error"]))}</div>' if a.get("error") else ""
        rows.append([f'{site_ui.dot(state_of(a["status"]))}<code>{e(a["attr"])}</code>{error}',
                     f'<span class=nowrap>{e(a.get("system") or "")}</span>',
                     status_pill(a["status"]) + cached, e(took(a["started_at"], a["finished_at"])),
                     f'<span class=actions>{log}{redo}</span>'])
    table = site_ui.table(["attribute", "system", "status", "took", ""], rows, numeric=(3, 4)) if rows \
        else '<div class=empty>nothing evaluated yet</div>'
    error = (f'<section class="set danger"><h3>{site_ui.dot("fail")}error</h3><div><pre>{e(b["error"])}</pre></div></section>'
             if b.get("error") else "")
    warnings = "".join(f'<div class=flash>{e(w["level"])}: {e(w["message"])} ×{w["count"]}</div>' for w in b.get("eval_warnings") or [])
    target = f"PR #{b['pr_number']}" if b.get("pr_number") else b["branch"]
    counts = {}
    for a in attrs:
        counts[state_of(a["status"])] = counts.get(state_of(a["status"]), 0) + 1
    summary = (status_pill(b["status"]) + f'<span>{e(target)}</span><code>{e(b["commit_sha"])}</code>'
               f'<span>started {e(when(b["started_at"]))}</span><span>took {e(took(b["started_at"], b["finished_at"]) or "—")}</span>')
    band = repo_band(user, forge, owner, name, "builds", title=f"Build #{number}", ico="builds",
                     crumbs=[(base, name)], summary=summary)
    note = " · ".join(f"{n} {word}" for s, word in (("fail", "failed"), ("warn", "building"), ("ok", "ok"), ("none", "other"))
                      if (n := counts.get(s)))
    body = f'{actions}{error}{warnings}' + site_ui.section("Attributes", table, note=note)
    return layout(f"{owner}/{name} #{number}", body, user, flash, "repos", band)


def log_page(user, forge, owner, name, number, attr, flash):
    base = page_url(forge, owner, name)
    path = f"/repos/{forge}/{quote(owner)}/{quote(name)}/builds/{number}/logs/raw/{quote(attr)}?tail=2000"
    try:
        text = service_api("GET", path, user, raw=True)
    except RuntimeError:
        text = "no log for this attribute (yet)"
    band = repo_band(user, forge, owner, name, "builds", title=attr, ico="attrs", small="last 2000 lines",
                     crumbs=[(base, name), (f"{base}/{number}", f"#{number}")],
                     summary=f'<a href="{base}/{number}">back to build #{number}</a>')
    return layout(f"{attr} log", f'<pre class=log>{e(text)}</pre>', user, flash, "repos", band)


def builders_page(user, flash):
    state = load()
    machines = state["machines"]

    def options(chosen):
        return "".join(f'<option value="{e(n)}"{" selected" if n == chosen else ""}>{e(n)}</option>' for n in sorted(machines))
    systems = sorted(set(state["systems"]) | set(SYSTEMS))
    rows = []
    for system in systems:
        on = state["systems"].get(system, "")
        rows.append([f'<span class=nowrap>{site_ui.dot("ok" if on in machines else "warn")}<code>{e(system)}</code></span>',
                     f'<form method=post action="/-/builders/system" class="row inline">'
                     f'<input type=hidden name=system value="{e(system)}"><select name=machine><option value="">nobody</option>'
                     f'{options(on)}</select><button class="ghost small">Set</button></form>',
                     check_result("system:" + system),
                     f'<form method=post action="/-/builders/test" class=inline><input type=hidden name=system value="{e(system)}">'
                     f'<button class="ghost small">Test build</button></form>'])
    add_system = site_ui.reveal("Add system", (
        '<form method=post action="/-/builders/system" class=fields>'
        '<label for=new-system>system</label><input id=new-system name=system placeholder="e.g. riscv64-linux" required>'
        f'<label>builds on</label><select name=machine><option value="">nobody</option>{options("")}</select>'
        '<span></span><button>Add system</button></form>'))
    tiles = ""
    for name, m in sorted(machines.items()):
        key = m.get("hostKey") or ""
        used = ", ".join(s for s, n in sorted(state["systems"].items()) if n == name)
        hidden = f'<input type=hidden name=name value="{e(name)}">'
        checked = check_state("machine:" + name)
        tile_state = "none" if not m.get("enabled", True) else "warn" if not key else checked or "ok"
        edit = site_ui.reveal("Edit", (
            f'<form method=post action="/-/builders/machine" class=fields>{hidden}'
            f'<label>address</label><input name=address value="{e(m["address"])}">'
            f'<label>ssh user</label><input name=user value="{e(m["user"])}">'
            f'<label>jobs</label><input name=jobs value="{e(m["jobs"])}" title="parallel jobs">'
            f'<label>speed</label><input name=speed value="{e(m["speed"])}" title="speed factor">'
            f'<label>features</label><input name=features value="{e(m["features"])}">'
            f'<label>enabled</label><label class=check><input type=checkbox name=enabled'
            f'{" checked" if m.get("enabled", True) else ""}> builds</label>'
            f'<span></span><button class=small>Save</button></form>'), ico="settings", kind="ghost")
        foot = (f'<form method=post action="/-/builders/check" class=inline>{hidden}<button class="ghost small">Check</button></form>'
                f'<form method=post action="/-/builders/hostkey" class=inline>{hidden}<button class="ghost small">Fetch host key</button></form>'
                f'<form method=post action="/-/builders/remove" class=inline onsubmit="return confirm(\'Remove {e(name)}?\')">'
                f'{hidden}<button class="danger small">Remove</button></form>{edit}')
        tiles += site_ui.tile(name, [
            ("address", f'<code>{e(m["address"])}</code>'), ("user", e(m["user"])),
            ("jobs", f'{e(m["jobs"])} <span class=mute>· speed {e(m["speed"])}</span>'),
            ("features", e(m["features"].replace(",", ", ")) or '<span class=mute>none</span>'),
            ("builds", e(used) or '<span class=mute>nothing yet</span>'),
            ("host key", f'<code>{e(key[:24])}…</code>' if key else site_ui.pill("warn", "none, fetch it")),
            ("check", check_result("machine:" + name))], tile_state,
            note="" if m.get("enabled", True) else site_ui.pill("none", "off"), foot=foot)
    add_machine = site_ui.reveal("Add machine", (
        '<form method=post action="/-/builders/machine" class=fields>'
        '<label for=new-name>name</label><input id=new-name name=name placeholder="a-z 0-9 -" required>'
        '<label for=new-address>address</label><input id=new-address name=address placeholder="e.g. 10.77.0.10" required>'
        '<label>ssh user</label><input name=user value=nix-ssh>'
        '<label>jobs</label><input name=jobs value=4><label>speed</label><input name=speed value=1>'
        '<label>features</label><input name=features value="big-parallel,kvm,nixos-test,benchmark">'
        '<input type=hidden name=enabled value=on><span></span><button>Add machine</button></form>'))
    idle = sum(1 for s in systems if state["systems"].get(s, "") not in machines)
    keyless = sum(1 for m in machines.values() if not m.get("hostKey"))
    summary = pills(("", plural(len(machines), "machine")), ("", plural(len(systems), "system")),
                    ("warn", f"{idle} without a machine" if idle else ""), ("warn", f"{keyless} without a host key" if keyless else ""))
    band = site_ui.band("Builders", "cpu", summary=summary)
    body = (site_ui.section("Systems", site_ui.table(["system", "builds on", "last test", ""], rows, numeric=(3,)),
                            note="each builds on one machine; the next build uses a change here")
            + add_system
            + site_ui.section("Machines", '<p class=mute>Reached over SSH as nix-ssh with this container\'s key. Any IP '
                              'address hive reaches works (LAN, NetBird, cicd0); set a machine up with <code>ci-builder setup</code>, '
                              'or <code>bresilla.nix.ciBuilder</code> on NixOS.</p>'
                              + (f'<div class="grid machines">{tiles}</div>' if tiles else '<div class=empty>no machines yet</div>')
                              + add_machine))
    return layout("builders", body, user, flash, "builders", band)


def settings_page(user, flash):
    fields, saved_count = "", 0
    for name, label in FIELDS:
        saved = bool(secret_value(name))
        saved_count += saved
        fields += (f'<label for="secret-{name}">{e(label)} '
                   f'{site_ui.pill("ok", "saved") if saved else site_ui.pill("fail", "missing")}</label>'
                   f'<input type=password id="secret-{name}" name="{name}" autocomplete=off '
                   f'placeholder="{"saved; type to replace" if saved else "not set"}">')
    state = muros_state()
    running = "ok" if state == "active" else "fail"
    summary = pills((running, f"Muros {state}"),
                    ("ok" if saved_count == len(FIELDS) else "fail", f"{saved_count} of {len(FIELDS)} secrets saved"))
    band = site_ui.band("Settings", "settings", summary=summary)
    tiles = (site_ui.tile("Muros", [("service", "<code>murosd.service</code>"), ("state", site_ui.pill(running, state)),
                                    ("runs", "every build")], running)
             + site_ui.tile("Accounts", [("sign in", '<a href="https://id.bresilla.com">id.bresilla.com</a>'),
                                         ("build_users", "may sign in"), ("build_admins", "may run things")]))
    where = site_ui.table(["token", "where to get it"], [
        ["attic token", '<span class=mute>cache.bresilla.com → Settings → auth tokens, all caches: name '
                        '<code>ci</code>, pull and push</span>'],
        ["pin token", '<span class=mute>cache.bresilla.com → Settings → pin token</span>']])
    secrets_form = ('<p class=mute>Saving restarts Muros with them; an empty field keeps what is saved, and nothing '
                    f'saved is shown again.</p><form method=post action="/-/settings" class="fields secrets">{fields}'
                    '<span></span><button>Save and restart Muros</button></form>'
                    + site_ui.reveal("Where the tokens come from", where, ico="key", kind="ghost"))
    body = f'<div class=grid>{tiles}</div>' + site_ui.section("Secrets", secrets_form, "ok" if saved_count == len(FIELDS) else "fail")
    return layout("settings", body, user, flash, "settings", band)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply(self, code, body):
        csrf = getattr(VIEW, "csrf", "")
        if csrf:
            hidden = f'<input type=hidden name=csrf value="{e(csrf)}">'
            body = re.sub(r"(<form\b[^>]*>)", lambda match: match[0] + hidden, body)
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        if getattr(VIEW, "set_cookie", ""):
            self.send_header("Set-Cookie", VIEW.set_cookie)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, to, flash="", headers=()):
        self.send_response(303)
        self.send_header("Location", to + ("?m=" + quote(flash) if flash else ""))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()

    def user(self):
        VIEW.csrf, VIEW.set_cookie = "", ""
        backend.VIEW.user = None
        if self.client_address[0] not in ("127.0.0.1", "::1"):
            return None
        if self.headers.get("Host") != urllib.parse.urlsplit(backend.ORIGIN).netloc:
            return None
        for header in ("X-Forwarded-Preferred-Username", "X-Forwarded-User", "X-Forwarded-Groups"):
            if len(self.headers.get_all(header, [])) > 1:
                return None
        name = self.headers.get("X-Forwarded-Preferred-Username") or self.headers.get("X-Forwarded-User")
        VIEW.name, VIEW.path = name or None, self.path
        admin = "admin" in self.headers.get("X-Forwarded-Groups", "").split(",")
        backend.VIEW.user = name if name and admin else None
        if backend.VIEW.user:
            cookie = SimpleCookie()
            try:
                cookie.load(self.headers.get("Cookie", ""))
            except ValueError:
                cookie = SimpleCookie()
            nonce = cookie[COOKIE].value if COOKIE in cookie else ""
            if not re.fullmatch(r"[a-f0-9]{64}", nonce):
                nonce = secrets.token_hex(32)
                secure = "; Secure" if backend.ORIGIN.startswith("https:") else ""
                VIEW.set_cookie = f"{COOKIE}={nonce}; Path=/; HttpOnly; SameSite=Strict{secure}"
            VIEW.csrf = hmac.new(CSRF_KEY, (name + "\0" + nonce).encode(), hashlib.sha256).hexdigest()
        return backend.VIEW.user

    def need_admin(self):
        # Signed out: to id.bresilla.com and back here. Signed in, not an admin: say so.
        if not getattr(VIEW, "name", None):
            return self.redirect(f"/oauth2/start?rd={quote(self.path)}")
        return self.redirect("/", ADMINS_ONLY)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        flash = urllib.parse.parse_qs(url.query).get("m", [""])[0]
        parts = [urllib.parse.unquote(p) for p in url.path.strip("/").split("/") if p]
        user = self.user()
        try:
            if not parts:
                return self.reply(200, repos_page(user, flash))
            if parts[:2] in (["-", "builders"], ["-", "settings"]):
                if not user:
                    return self.need_admin()
                return self.reply(200, builders_page(user, flash) if parts[1] == "builders" else settings_page(user, flash))
            if parts[:2] == ["-", "repo"] and len(parts) == 4 and all(SEGMENT.fullmatch(p) for p in parts[2:4]):
                return self.reply(200, owner_page(user, parts[2], parts[3], flash))
            if parts[:2] == ["-", "repo"] and len(parts) >= 5 and all(SEGMENT.fullmatch(p) for p in parts[2:5]):
                forge, owner, name, rest = parts[2], parts[3], parts[4], parts[5:]
                if not rest:
                    return self.reply(200, repo_page(user, forge, owner, name, flash))
                if rest == ["settings"]:
                    if not user:
                        return self.need_admin()
                    return self.reply(200, repo_rules.page(sys.modules[__name__], user, forge, owner, name, flash))
                if rest[0].isdigit() and len(rest) == 1:
                    return self.reply(200, build_page(user, forge, owner, name, int(rest[0]), flash))
                if rest[0].isdigit() and len(rest) == 3 and rest[1] == "log":
                    return self.reply(200, log_page(user, forge, owner, name, int(rest[0]), rest[2], flash))
        except (OSError, RuntimeError, ValueError, KeyError, sqlite3.Error) as err:
            return self.reply(502, layout("Muros", f'<div class="card empty">Muros is not answering: {e(err)}<br>'
                                          f'Check its secrets on <a href="/-/settings">Settings</a>.</div>', user,
                                          band=site_ui.band("Muros is not answering", "x", crumbs=[("/", "Repositories")])))
        return self.reply(404, layout("not found", '<div class="card empty">nothing at this address</div>', user,
                                      band=site_ui.band("Not found", "paths", crumbs=[("/", "Repositories")])))

    def do_POST(self):
        user = self.user()
        path = urllib.parse.urlparse(self.path).path
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            return self.reply(400, "invalid content length")
        if not 0 <= length <= 65536:
            return self.reply(413, "form too large")
        form = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(length).decode()).items()}
        origin = self.headers.get("Origin") or self.headers.get("Referer", "")
        parsed = urllib.parse.urlsplit(origin)
        expected = urllib.parse.urlsplit(backend.ORIGIN)
        if (parsed.scheme, parsed.netloc) != (expected.scheme, expected.netloc):
            return self.reply(403, layout("refused", '<div class="card empty">cross-site request refused</div>', None))
        if not user:
            return self.redirect("/", ADMINS_ONLY)
        if VIEW.set_cookie or not hmac.compare_digest(form.get("csrf", ""), VIEW.csrf):
            return self.reply(403, layout("refused", '<div class="card empty">reload this page and try again</div>', user))
        try:
            with backend.MUTATION:
                return self.manage(path, form, user)
        except (OSError, RuntimeError, ValueError, KeyError, sqlite3.Error) as err:
            back = (self.headers.get("Referer") or "/").split("?")[0]
            return self.redirect(urllib.parse.urlparse(back).path or "/", f"failed: {err}")

    def manage(self, path, form, user):
        if path == "/-/settings":
            values = {name: form.get(name, "").strip() for name, _ in FIELDS}
            values = {k: v for k, v in values.items() if v and not re.search(r"\s", v)}
            if values:
                save_secrets(values)
            return self.redirect("/-/settings", f"saved {len(values)}; Muros restarts with them" if values else "nothing changed")
        if path == "/-/repos/add":
            url, branch = form.get("url", "").strip(), form.get("branch", "main").strip()
            interval = form.get("interval", "60").strip()
            name = repo_name(url)
            if not GIT_URL.fullmatch(url) or not name or not BRANCH.fullmatch(branch) \
                    or not interval.isdigit() or not 30 <= int(interval) <= 86400:
                return self.redirect("/", "needs a git URL (https://, ssh:// or git@host:path), a branch, and 30 to 86400 seconds")
            repos = load_repos()
            if name in repos:
                return self.redirect("/", f"{name} is already there")
            repos[name] = {"name": name, "url": url, "default_branch": branch, "poll_interval": int(interval)}
            save_repos(repos)
            return self.redirect("/", f"added {name}; Muros restarts and checks it now")
        parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/")]
        if parts[:2] == ["-", "repo"] and len(parts) >= 6 and all(SEGMENT.fullmatch(p) for p in parts[2:5]):
            forge, owner, name, rest = parts[2], parts[3], parts[4], parts[5:]
            back = f"/-/repo/{forge}/{quote(owner)}/{quote(name)}"
            if rest == ["settings"]:
                service_api("PUT", repo_path(forge, owner, name) + "/settings", user, body=repo_rules.parse(form))
                return self.redirect(back + "/settings", "rules saved; .muros.lua takes precedence when present")
            if rest == ["caches"]:
                caches = form.get("caches", "").replace(",", " ").split()
                if not 1 <= len(caches) <= 32:
                    return self.redirect(back + "/settings", "list between 1 and 32 caches")
                service_api("PUT", repo_path(forge, owner, name) + "/caches", user, body={"caches": caches})
                return self.redirect(back + "/settings", "allowed caches: " + " ".join(caches))
            if rest == ["caches", "clear"]:
                service_api("DELETE", repo_path(forge, owner, name) + "/caches", user, raw=True)
                return self.redirect(back + "/settings", "allowed caches reset to the server default")
            if rest == ["trigger"]:
                result = service_api("POST", repo_path(forge, owner, name) + "/trigger", user)
                action = "already active" if result["action"] == "active" else result["action"]
                return self.redirect(f'{back}/{result["number"]}', f'build #{result["number"]}: {action}')
            if rest == ["remove"]:
                repo = service_api("GET", repo_path(forge, owner, name), user)
                if repo["enabled"]:
                    service_api("POST", repo_path(forge, owner, name) + "/disable", user, raw=True)
                repos = load_repos()
                repos.pop(f"{owner}/{name}", None)
                save_repos(repos)
                return self.redirect(page_url(forge, owner), f"removed {owner}/{name}; its builds go once Muros restarts")
            if rest == ["toggle"]:
                repo = service_api("GET", repo_path(forge, owner, name), user)
                service_api("POST", repo_path(forge, owner, name) + ("/disable" if repo["enabled"] else "/enable"), user, raw=True)
                return self.redirect(back, f"{owner}/{name} {'disabled' if repo['enabled'] else 'enabled'}")
            if rest[0].isdigit() and rest[1:] in (["restart"], ["cancel"]):
                service_api("POST", repo_path(forge, owner, name) + f"/builds/{rest[0]}/{rest[1]}", user, raw=True)
                return self.redirect(f"{back}/{rest[0]}", f"build #{rest[0]}: {rest[1]} sent")
            if rest[0].isdigit() and len(rest) == 4 and rest[1] == "attr" and rest[3] == "restart":
                service_api("POST", repo_path(forge, owner, name) + f"/builds/{rest[0]}/attrs/{quote(rest[2])}/restart", user, raw=True)
                return self.redirect(f"{back}/{rest[0]}", f"{rest[2]}: restart sent")
        if path.startswith("/-/builders/"):
            return self.builders(path.removeprefix("/-/builders/"), form)
        return self.redirect("/", "not found")

    def builders(self, action, form):
        state = load()
        name = form.get("name", "")
        if action == "system":
            system, machine = form.get("system", ""), form.get("machine", "")
            if not SYSTEM.fullmatch(system) or (machine and machine not in state["machines"]):
                return self.redirect("/-/builders", "systems look like x86_64-linux")
            state["systems"][system] = machine
            save(state)
            return self.redirect("/-/builders", f"{system} builds on {machine or 'nobody'}")
        if action == "test":
            system = form.get("system", "")
            if SYSTEM.fullmatch(system):
                test_system(system)
            return self.redirect("/-/builders", f"test build for {system} started; reload in a moment")
        if action == "machine":
            m = {"address": form.get("address", ""), "user": form.get("user", "nix-ssh"), "jobs": form.get("jobs", "4"),
                 "speed": form.get("speed", "1"), "features": form.get("features", ""), "enabled": form.get("enabled") == "on"}
            valid = (NAME.fullmatch(name) and ADDRESS.fullmatch(m["address"]) and NAME.fullmatch(m["user"])
                     and m["jobs"].isdigit() and m["speed"].isdigit() and FEATURES.fullmatch(m["features"]))
            if not valid:
                return self.redirect("/-/builders", "names: a-z 0-9 -; jobs and speed: numbers")
            m["jobs"], m["speed"] = int(m["jobs"]), int(m["speed"])
            old = state["machines"].get(name, {})
            m["hostKey"] = old.get("hostKey", "") if old.get("address") == m["address"] else ""
            state["machines"][name] = m
            save(state)
            return self.redirect("/-/builders", f"saved {name}" + ("" if m["hostKey"] else "; fetch its host key next"))
        if name not in state["machines"]:
            return self.redirect("/-/builders", "no such machine")
        if action == "remove":
            del state["machines"][name]
            state["systems"] = {s: (n if n != name else "") for s, n in state["systems"].items()}
            save(state)
            return self.redirect("/-/builders", f"removed {name}")
        if action == "check":
            check_machine(name, state["machines"][name])
            return self.redirect("/-/builders", f"checking {name}; reload in a moment")
        if action == "hostkey":
            key = fetch_host_key(state["machines"][name]["address"])
            if not key or not HOST_KEY.fullmatch(key):
                return self.redirect("/-/builders", f"{name} did not answer with an ed25519 host key")
            state["machines"][name]["hostKey"] = key
            save(state)
            return self.redirect("/-/builders", f"saved {name}'s host key")
        return self.redirect("/-/builders", "not found")


if __name__ == "__main__":
    os.umask(0o077)
    backend.initialize()
    ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("CI_PORT", "8091"))), Handler).serve_forever()
