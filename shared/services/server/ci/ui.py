"""build.bresilla.com: CI for any git repository, made like the cache UI.

nixbot runs underneath and does the work (polling repositories, evaluation, builds);
this page is the whole site on top of it, talking to nixbot's JSON API over its
socket as the signed-in user. Accounts are made on hive with
`sudo ci-user add|remove|list`.

Builders: each system builds on one machine, reached over SSH (ssh-ng, user
nix-ssh) with the container's own key; saving writes /var/lib/ci/machines,
which the Nix daemon reads afresh for every remote build.
"""
import base64
import getpass
import hashlib
import hmac
import html
import http.client
import json
import os
import pwd
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote

STATE = "/var/lib/ci-builders/builders.json"
# The repositories nixbot polls; it reads this at start, and restarts when it changes.
REPOS = "/var/lib/ci-builders/repos.json"
USERS = "/var/lib/ci-builders/users.json"
SECRETS = "/var/lib/ci/secrets"
MACHINES = "/var/lib/ci/machines"
KEY = "/var/lib/ci/builder_ed25519"
# The same key, owned by this page, for its own checks.
CHECK_KEY = "/var/lib/ci-builders/builder_ed25519"
NIXBOT = "/run/nixbot/web.sock"
SYSTEMS = os.environ.get("CI_SYSTEMS", "").split()
USER_NAME = re.compile(r"[a-z0-9_-]{1,32}")
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
SYSTEM = re.compile(r"[a-z0-9_]+-[a-z]+")
ADDRESS = re.compile(r"[A-Za-z0-9.:-]{1,253}")
HOST_KEY = re.compile(r"ssh-(ed25519|rsa) [A-Za-z0-9+/=]{20,800}")
FEATURES = re.compile(r"[a-z0-9,-]{0,200}")
SEGMENT = re.compile(r"[A-Za-z0-9._-]{1,100}")
GIT_URL = re.compile(r"(https?://|ssh://)[A-Za-z0-9._~:@%/+-]{3,300}|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._~/+-]{1,300}")
BRANCH = re.compile(r"[A-Za-z0-9._/-]{1,100}")
SESSION_DAYS = 14
# Settings fields: file name and label.
FIELDS = [
    ("attic-token", "attic token that may push to the bresilla cache"),
]
sessions = {}
results = {}
lock = threading.Lock()

STYLE = open(os.environ["CI_STYLE"]).read() if "CI_STYLE" in os.environ else ""

# Same rule as gitea and the cache: a new hue on refresh, the saved one while clicking around.
SCRIPT = """
const reload = performance.getEntriesByType("navigation")[0]?.type === "reload";
let hue = localStorage.getItem("accent-hue");
if (reload || hue === null) { hue = Math.floor(Math.random() * 360); localStorage.setItem("accent-hue", hue); }
document.documentElement.style.setProperty("--accent", `hsl(${hue} 65% 50%)`);
// The favicon is the header logo in the same colour, as on gitea.
document.addEventListener("DOMContentLoaded", () => {
  const mark = document.querySelector("header svg");
  if (!mark) return;
  const link = document.createElement("link");
  link.rel = "icon";
  link.type = "image/svg+xml";
  link.href = "data:image/svg+xml," + encodeURIComponent(mark.outerHTML.replaceAll("currentColor", `hsl(${hue} 65% 50%)`));
  document.head.append(link);
});
"""

ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{}</svg>'
ICONS = {name: ICON.format(shape) for name, shape in {
    "repo": '<path d="M4 19V5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2"/><path d="M19 19H6"/>',
    "builds": '<path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1"/>',
    "attrs": '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
    "builders": '<rect x="3" y="4" width="18" height="6" rx="1"/><rect x="3" y="14" width="18" height="6" rx="1"/><path d="M7 7h.01M7 17h.01"/>',
    "settings": '<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/>',
    "private": '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
}.items()}


def logo():
    with open(os.environ["CI_LOGO"]) as f:
        return re.sub(r'fill="#[0-9a-fA-F]+"', 'fill="currentColor"', f.read().split("?>", 1)[-1])


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


def took(start, end):
    if not start or not end:
        return ""
    try:
        s = (datetime.fromisoformat(str(end).replace("Z", "+00:00")) - datetime.fromisoformat(str(start).replace("Z", "+00:00"))).total_seconds()
    except ValueError:
        return ""
    return f"{int(s // 60)}m {int(s % 60)}s" if s >= 60 else f"{int(s)}s"


def status_pill(status):
    cls = {"succeeded": "ok", "failed": "bad", "cancelled": "mute", "skipped": "mute"}.get(status, "run")
    return f'<span class="pill {cls}">{e(status)}</span>'


# nixbot, over its socket, as the signed-in user.

class UnixConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(30)
        self.sock.connect(NIXBOT)


def nixbot(method, path, user=None, raw=False):
    conn = UnixConnection("localhost")
    headers = {"Host": os.environ.get("CI_DOMAIN", "localhost"), "Accept": "application/json"}
    if user:
        headers["X-Remote-User"] = user
    conn.request(method, path, headers=headers)
    response = conn.getresponse()
    body = response.read()
    conn.close()
    if response.status >= 400:
        raise RuntimeError(f"nixbot answered {response.status} for {path}")
    return body.decode(errors="replace") if raw else (json.loads(body) if body else None)


def repo_path(forge, owner, name):
    return f"/api/repos/{forge}/{quote(owner)}/{quote(name)}"


# Builders: saved state, and the machines file written from it.

def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except FileNotFoundError:
        return json.loads(os.environ.get("CI_SEED", '{"machines": {}, "systems": {}}'))


def save(state):
    tmp = STATE + ".new"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, STATE)
    lines = []
    for name, m in sorted(state["machines"].items()):
        systems = sorted(s for s, on in state["systems"].items() if on == name)
        if not m.get("enabled", True) or not systems:
            continue
        host_key = base64.b64encode(m["hostKey"].encode()).decode() if m.get("hostKey") else "-"
        lines.append(f"ssh-ng://{m['user']}@{m['address']} {','.join(systems)} {KEY} "
                     f"{m['jobs']} {m['speed']} {m['features'] or '-'} - {host_key}")
    tmp = MACHINES + ".new"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, MACHINES)


def store_url(m):
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
    with lock:
        results[key] = (text, time.strftime("%H:%M:%S"))


def check_machine(name, m):
    argv = ["nix", "--extra-experimental-features", "nix-command", "store", "info", "--store", store_url(m)]
    threading.Thread(target=run_check, args=("machine:" + name, argv, lambda _: "reachable"), daemon=True).start()


def test_system(system):
    # A tiny build that reports the builder's CPU count, unique so it always runs.
    expr = ('derivation { name = "ci-check"; system = "%s"; builder = "/bin/sh"; t = builtins.currentTime;'
            ' args = [ "-c" "n=0; while read -r l; do case $l in processor*) n=$((n+1));; esac;'
            ' done </proc/cpuinfo; echo $n >$out" ]; }') % system
    argv = ["nix", "--extra-experimental-features", "nix-command", "build", "--impure", "--no-link",
            "--print-out-paths", "--expr", expr]

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
        return '<span class=mute>not checked</span>'
    cls = "run" if text == "running" else ("bad" if text.startswith("failed") else "ok")
    return f'<span class={cls}>{e(text)}</span> <span class=mute>{e(at)}</span>'


# Accounts: scrypt-hashed, made on hive with `sudo ci-user add|remove|list`.

def password_hash(password, salt):
    return hashlib.scrypt(password.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32).hex()


def load_users():
    try:
        with open(USERS) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def check_login(name, password):
    row = load_users().get(name)
    # Hash even for unknown names, so timing doesn't tell which names exist.
    salt, stored = (bytes.fromhex(row["salt"]), row["hash"]) if row else (b"\0" * 16, "0" * 64)
    return row is not None and hmac.compare_digest(password_hash(password, salt), stored)


def users_cli(args):
    action, name = (args + [None, None])[:2]
    users = load_users()
    if action == "list":
        for user in sorted(users):
            print(user)
        return
    if action == "add" and name and USER_NAME.fullmatch(name):
        password = getpass.getpass(f"new password for {name} (at least 8 characters): ")
        if password != getpass.getpass("same password again: "):
            sys.exit("the two passwords differ; nothing saved")
        if len(password) < 8:
            sys.exit(f"too short: {len(password)} characters, at least 8; nothing saved")
        salt = secrets.token_bytes(16)
        users[name] = {"salt": salt.hex(), "hash": password_hash(password, salt)}
    elif action == "remove" and name in users:
        del users[name]
    else:
        sys.exit("usage: ci-user add|remove <name> | list   (names: a-z 0-9 _ -)")
    tmp = USERS + ".new"
    with open(tmp, "w") as f:
        json.dump(users, f, indent=2)
    owner = pwd.getpwnam("ci-builders")
    os.chown(tmp, owner.pw_uid, owner.pw_gid)
    os.chmod(tmp, 0o600)
    os.replace(tmp, USERS)
    print(f"{name}: {'saved' if action == 'add' else 'removed'}")


# Secrets: one file each; a touch of "saved" restarts nixbot with them.

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


def nixbot_state():
    out = subprocess.run(["systemctl", "is-active", "nixbot.service"], capture_output=True, text=True)
    return out.stdout.strip() or "unknown"


# Pages, laid out as on the cache UI.

def layout(title, body, user, flash="", nav="repos"):
    signed_in = [("builders", "/-/builders", "Builders"), ("settings", "/-/settings", "Settings")]
    links = [("repos", "/", "Repositories")] + (signed_in if user else [])
    nav_html = "".join(f'<a href="{href}" class="{"on" if key == nav else ""}">{label}</a>' for key, href, label in links)
    if user:
        right = (f'<span class=mute>{e(user)}</span><form class=inline method=post action="/-/logout">'
                 f'<button class="ghost small">Sign out</button></form>')
    else:
        right = '<a href="/-/login" class=item>Sign in</a>'
    note = f'<div class=flash>{e(flash)}</div>' if flash else ""
    return f"""<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1"><title>{e(title)}</title>
<script>{SCRIPT}</script><style>{STYLE}</style></head><body>
<header>{logo()}<a href="/">build</a><nav>{nav_html}</nav><div class=who>{right}</div></header>
<main>{note}{body}</main></body></html>"""


def post_button(action, label, cls="ghost small", confirm=""):
    check = f' onsubmit="return confirm(\'{e(confirm)}\')"' if confirm else ""
    return f'<form class=inline method=post action="{e(action)}"{check}><button class="{cls}">{e(label)}</button></form>'


def repos_page(user, flash):
    repos = nixbot("GET", "/api/repos", user) or []
    repos.sort(key=lambda r: (not r["enabled"], r["owner"], r["name"]))
    cards = ""
    for r in repos:
        base = f'/-/repo/{r["forge"]}/{quote(r["owner"])}/{quote(r["name"])}'
        last = ""
        if r["enabled"]:
            page = nixbot("GET", repo_path(r["forge"], r["owner"], r["name"]) + "/builds?page=1", user) or {}
            items = page.get("items") or []
            if items:
                b = items[0]
                last = f'{status_pill(b["status"])} <span class=mute>#{b["number"]} on {e(b["branch"])} · {e(when(b["created_at"]))}</span>'
            else:
                last = '<span class=mute>no builds yet</span>'
        actions = ""
        if user:
            actions = (post_button(f"{base}/toggle", "Disable" if r["enabled"] else "Enable",
                                   "ghost small" if r["enabled"] else "small")
                       + post_button(f"{base}/remove", "Remove", "danger small", f'Remove {r["owner"]}/{r["name"]}?'))
        private = "<span class=pill>private</span> " if r["private"] else ""
        cards += (f'<div class="card cachecard"><div class=top><a href="{base}"><b>{e(r["owner"])}/{e(r["name"])}</b></a>'
                  f'<span>{private}{actions}</span></div><div>{last or "<span class=pill>off</span>"}</div>'
                  f'<div class=mute><code>{e(r["url"])}</code> · {e(r["default_branch"])}</div></div>')
    add = ""
    if user:
        add = ('<section class=set><h3>add a repository</h3><div><p class=mute>Any git URL this server can fetch. '
               'Its <code>flake.nix</code> is built from the <code>checks</code> output, for every system it lists; '
               'new commits on the branch are picked up within the interval.</p>'
               '<form method=post action="/-/repos/add" class=row>'
               '<input name=url placeholder="https://git.bresilla.com/bresilla/termworks" required size=48>'
               '<input name=branch value=main size=10 title=branch>'
               '<input name=interval value=60 size=4 title="seconds between checks"><button>Add</button></form>'
               '</div></section>')
    if not cards:
        cards = '<div class="card empty">no repositories yet</div>'
    return layout("repositories", f'<div class=pagehead><h1>Repositories</h1></div>{add}{cards}', user, flash, "repos")


def repo_name(url):
    """owner/name from a git URL, as nixbot lists pull-based repositories."""
    path = re.sub(r"^[a-z+]+://[^/]+/|^[^@/]+@[^:]+:", "", url).removesuffix("/").removesuffix(".git")
    parts = [p for p in path.split("/") if p]
    return "/".join(parts[-2:]) if len(parts) >= 2 else None


def load_repos():
    try:
        with open(REPOS) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_repos(repos):
    tmp = REPOS + ".new"
    with open(tmp, "w") as f:
        json.dump(repos, f, indent=2)
    os.chmod(tmp, 0o644)
    os.replace(tmp, REPOS)


def repo_page(user, forge, owner, name, flash):
    base = f"/-/repo/{forge}/{quote(owner)}/{quote(name)}"
    page = nixbot("GET", repo_path(forge, owner, name) + "/builds?page=1", user) or {}
    rows = ""
    for b in page.get("items") or []:
        target = f"PR #{b['pr_number']}" if b.get("pr_number") else b["branch"]
        rows += (f'<tr><td><a href="{base}/{b["number"]}">#{b["number"]}</a></td><td>{status_pill(b["status"])}</td>'
                 f'<td>{e(target)}</td><td><code>{e(b["commit_sha"][:10])}</code></td>'
                 f'<td class=mute>{e(when(b["created_at"]))}</td><td class=num>{e(took(b["started_at"], b["finished_at"]))}</td></tr>')
    rows = rows or '<tr><td colspan=6 class=mute>no builds yet: push a commit</td></tr>'
    body = (f'<div class=crumbs><a href="/">Repositories ›</a></div>'
            f'<div class=pagehead><h1>{ICONS["repo"]}{e(owner)}/{e(name)}</h1></div>'
            f'<section class=set><h3>builds</h3><div><table><tr><th>build</th><th>status</th><th>for</th><th>commit</th>'
            f'<th>started</th><th class=num>took</th></tr>{rows}</table></div></section>')
    return layout(f"{owner}/{name}", body, user, flash, "repos")


def build_page(user, forge, owner, name, number, flash):
    base = f"/-/repo/{forge}/{quote(owner)}/{quote(name)}"
    detail = nixbot("GET", repo_path(forge, owner, name) + f"/builds/{number}", user)
    b = detail["build"]
    actions = ""
    if user:
        actions = (post_button(f"{base}/{number}/restart", "Restart", "small")
                   + post_button(f"{base}/{number}/cancel", "Cancel", "danger small", "Cancel this build?"))
    rows = ""
    for a in sorted(detail["attributes"], key=lambda a: (a["status"] == "succeeded", a["attr"])):
        log = f'<a href="{base}/{number}/log/{quote(a["attr"], safe="")}">log</a>'
        redo = post_button(f'{base}/{number}/attr/{quote(a["attr"], safe="")}/restart', "Restart") if user else ""
        cached = " <span class=mute>cached</span>" if a.get("cached") else ""
        error = f'<div class=mute>{e(a["error"])}</div>' if a.get("error") else ""
        rows += (f'<tr><td><code>{e(a["attr"])}</code>{error}</td><td>{e(a.get("system") or "")}</td>'
                 f'<td>{status_pill(a["status"])}{cached}</td><td class=num>{e(took(a["started_at"], a["finished_at"]))}</td>'
                 f'<td class=num>{log} {redo}</td></tr>')
    rows = rows or '<tr><td colspan=5 class=mute>nothing evaluated yet</td></tr>'
    error = f'<section class="set danger"><h3>error</h3><div><pre>{e(b["error"])}</pre></div></section>' if b.get("error") else ""
    warnings = "".join(f'<div class=flash>{e(w["level"])}: {e(w["message"])} ×{w["count"]}</div>' for w in b.get("eval_warnings") or [])
    target = f"PR #{b['pr_number']}" if b.get("pr_number") else b["branch"]
    body = (f'<div class=crumbs><a href="/">Repositories ›</a> <a href="{base}">{e(owner)}/{e(name)} ›</a></div>'
            f'<div class=pagehead><div><h1>{ICONS["builds"]}Build #{number} {status_pill(b["status"])}</h1>'
            f'<div class=summary>{e(target)} · <code>{e(b["commit_sha"])}</code> · started {e(when(b["started_at"]))}'
            f' · took {e(took(b["started_at"], b["finished_at"]) or "—")}</div></div><div>{actions}</div></div>'
            f'{error}{warnings}<section class=set><h3>attributes</h3><div><table><tr><th>attribute</th><th>system</th>'
            f'<th>status</th><th class=num>took</th><th></th></tr>{rows}</table></div></section>')
    return layout(f"{owner}/{name} #{number}", body, user, flash, "repos")


def log_page(user, forge, owner, name, number, attr, flash):
    base = f"/-/repo/{forge}/{quote(owner)}/{quote(name)}"
    path = f"/repos/{forge}/{quote(owner)}/{quote(name)}/builds/{number}/logs/raw/{quote(attr)}?tail=2000"
    try:
        text = nixbot("GET", path, user, raw=True)
    except RuntimeError:
        text = "no log for this attribute (yet)"
    body = (f'<div class=crumbs><a href="/">Repositories ›</a> <a href="{base}">{e(owner)}/{e(name)} ›</a> '
            f'<a href="{base}/{number}">#{number} ›</a></div><div class=pagehead><h1>{ICONS["attrs"]}{e(attr)}</h1>'
            f'<div class=summary>last 2000 lines</div></div><pre>{e(text)}</pre>')
    return layout(f"{attr} log", body, user, flash, "repos")


def builders_page(user, flash):
    state = load()
    machines = state["machines"]

    def options(chosen):
        return "".join(f'<option value="{e(n)}"{" selected" if n == chosen else ""}>{e(n)}</option>' for n in sorted(machines))
    rows = ""
    for system in sorted(set(state["systems"]) | set(SYSTEMS)):
        on = state["systems"].get(system, "")
        rows += (f'<tr><td><code>{e(system)}</code></td><td><form method=post action="/-/builders/system" class="row inline">'
                 f'<input type=hidden name=system value="{e(system)}"><select name=machine><option value="">nobody</option>'
                 f'{options(on)}</select><button class="ghost small">Set</button></form></td>'
                 f'<td>{check_result("system:" + system)}</td><td class=num>'
                 f'<form method=post action="/-/builders/test" class=inline><input type=hidden name=system value="{e(system)}">'
                 f'<button class="ghost small">Test build</button></form></td></tr>')
    cards = ""
    for name, m in sorted(machines.items()):
        key = m.get("hostKey") or ""
        used = ", ".join(s for s, n in sorted(state["systems"].items()) if n == name) or "nothing yet"
        hidden = f'<input type=hidden name=name value="{e(name)}">'
        cards += (f'<div class=card><div class=top><b>{e(name)}</b><span>{check_result("machine:" + name)}</span></div>'
                  f'<div class=mute>builds {e(used)} · host key <code>{e(key[:28] + "…" if key else "none, fetch it")}</code></div>'
                  f'<form method=post action="/-/builders/machine" class=row>{hidden}'
                  f'<input name=address value="{e(m["address"])}" size=14 title=address>'
                  f'<input name=user value="{e(m["user"])}" size=8 title="ssh user">'
                  f'<input name=jobs value="{e(m["jobs"])}" size=3 title="parallel jobs">'
                  f'<input name=speed value="{e(m["speed"])}" size=3 title="speed factor">'
                  f'<input name=features value="{e(m["features"])}" size=30 title=features>'
                  f'<label><input type=checkbox name=enabled{" checked" if m.get("enabled", True) else ""}> on</label>'
                  f'<button class=small>Save</button></form><div>'
                  f'<form method=post action="/-/builders/check" class=inline>{hidden}<button class="ghost small">Check</button></form> '
                  f'<form method=post action="/-/builders/hostkey" class=inline>{hidden}<button class="ghost small">Fetch host key</button></form> '
                  f'<form method=post action="/-/builders/remove" class=inline onsubmit="return confirm(\'Remove {e(name)}?\')">'
                  f'{hidden}<button class="danger small">Remove</button></form></div></div>')
    body = (f'<div class=pagehead><h1>{ICONS["builders"]}Builders</h1></div>'
            f'<section class=set><h3>systems</h3><div><p class=mute>Each system builds on one machine; the next build uses '
            f'a change here.</p><table><tr><th>system</th><th>builds on</th><th>last test</th><th></th></tr>{rows}</table>'
            f'<form method=post action="/-/builders/system" class=row><input name=system placeholder="new system, e.g. riscv64-linux" required>'
            f'<select name=machine><option value="">nobody</option>{options("")}</select><button>Add system</button></form>'
            f'</div></section><section class=set><h3>machines</h3><div><p class=mute>Reached over SSH as nix-ssh with this '
            f'container\'s key. Any IP address hive reaches works (LAN, NetBird, cicd0); set a machine up with '
            f'<code>ci-builder setup</code>, or <code>bresilla.nix.ciBuilder</code> on NixOS.</p>{cards or "<div class=empty>no machines yet</div>"}'
            f'<form method=post action="/-/builders/machine" class=row><input name=name placeholder=name required size=8>'
            f'<input name=address placeholder="address, e.g. 10.77.0.10" required><input name=user value=nix-ssh size=8>'
            f'<input name=jobs value=4 size=3><input name=speed value=1 size=3>'
            f'<input name=features value="big-parallel,kvm,nixos-test,benchmark" size=30>'
            f'<input type=hidden name=enabled value=on><button>Add machine</button></form></div></section>')
    return layout("builders", body, user, flash, "builders")


def settings_page(user, flash):
    rows = ""
    for name, label in FIELDS:
        saved = bool(secret_value(name))
        rows += (f'<tr><td>{e(label)}</td><td><input type=password name="{name}" class=wide autocomplete=off '
                 f'placeholder="{"saved; type to replace" if saved else "not set"}"></td>'
                 f'<td class=num>{"<span class=ok>saved</span>" if saved else "<span class=bad>missing</span>"}</td></tr>')
    state = nixbot_state()
    body = (f'<div class=pagehead><h1>{ICONS["settings"]}Settings</h1></div>'
            f'<section class=set><h3>nixbot</h3><div><div class=stats><div><b>{e(state)}</b>the service that builds</div>'
            f'</div></div></section>'
            f'<section class=set><h3>secrets</h3><div><p class=mute>Saving restarts nixbot with them; an empty field keeps '
            f'what is saved, and nothing saved is shown again.</p><form method=post action="/-/settings">'
            f'<table><tr><th>what</th><th>value</th><th></th></tr>{rows}</table><p><button>Save and restart nixbot</button></p>'
            f'</form><table>'
            f'<tr><td>attic token</td><td class=mute>cache.bresilla.com → Settings → auth tokens, all caches: name '
            f'<code>ci</code>, pull and push</td></tr></table></div></section>'
            f'<section class=set><h3>accounts</h3><div><p class=mute>Accounts for this page are managed on the server: '
            f'<code>sudo ci-user add|remove|list</code>.</p></div></section>')
    return layout("settings", body, user, flash, "settings")


def login_page(flash=""):
    return layout("sign in", '<div class=pagehead><h1>Sign in</h1></div><form method=post action="/-/login" class=card style="max-width:360px">'
                  '<p><input class=wide name=user placeholder=user autocomplete=username required autofocus></p>'
                  '<p><input class=wide type=password name=password placeholder=password autocomplete=current-password required></p>'
                  '<button>sign in</button></form>', None, flash, "")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
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
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            name, expires = sessions.get(v, (None, 0)) if k == "ci_session" else (None, 0)
            if name and expires > time.time() and name in load_users():
                return name, v
        return None, None

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        flash = urllib.parse.parse_qs(url.query).get("m", [""])[0]
        parts = [urllib.parse.unquote(p) for p in url.path.strip("/").split("/") if p]
        user, _ = self.user()
        try:
            if not parts:
                return self.reply(200, repos_page(user, flash))
            if parts == ["-", "login"]:
                return self.reply(200, login_page(flash))
            if parts[:2] in (["-", "builders"], ["-", "settings"]):
                if not user:
                    return self.redirect("/-/login", "sign in first")
                return self.reply(200, builders_page(user, flash) if parts[1] == "builders" else settings_page(user, flash))
            if parts[:2] == ["-", "repo"] and len(parts) >= 5 and all(SEGMENT.fullmatch(p) for p in parts[2:5]):
                forge, owner, name, rest = parts[2], parts[3], parts[4], parts[5:]
                if not rest:
                    return self.reply(200, repo_page(user, forge, owner, name, flash))
                if rest[0].isdigit() and len(rest) == 1:
                    return self.reply(200, build_page(user, forge, owner, name, int(rest[0]), flash))
                if rest[0].isdigit() and len(rest) == 3 and rest[1] == "log":
                    return self.reply(200, log_page(user, forge, owner, name, int(rest[0]), rest[2], flash))
        except (OSError, RuntimeError, ValueError, KeyError) as err:
            return self.reply(502, layout("nixbot", f'<div class="card empty">nixbot is not answering: {e(err)}<br>'
                                          f'Check its secrets on <a href="/-/settings">Settings</a>.</div>', user))
        return self.reply(404, layout("not found", '<div class="card empty">not found</div>', user))

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        length = min(int(self.headers.get("Content-Length", 0)), 65536)
        form = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(length).decode()).items()}
        origin = self.headers.get("Origin")
        if origin and urllib.parse.urlparse(origin).netloc != self.headers.get("Host"):
            return self.reply(403, layout("refused", '<div class="card empty">cross-site request refused</div>', None))
        if path == "/-/login":
            name = form.get("user", "")
            if USER_NAME.fullmatch(name) and check_login(name, form.get("password", "")):
                sid = secrets.token_urlsafe(32)
                sessions[sid] = (name, time.time() + SESSION_DAYS * 86400)
                cookie = f"ci_session={sid}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age={SESSION_DAYS * 86400}"
                return self.redirect("/", f"signed in as {name}", [("Set-Cookie", cookie)])
            time.sleep(1)
            return self.redirect("/-/login", "wrong user or password")
        user, sid = self.user()
        if not user:
            return self.redirect("/-/login", "sign in first")
        if path == "/-/logout":
            sessions.pop(sid, None)
            return self.redirect("/", "signed out", [("Set-Cookie", "ci_session=; Path=/; Max-Age=0")])
        try:
            return self.manage(path, form, user)
        except (OSError, RuntimeError, ValueError, KeyError) as err:
            back = (self.headers.get("Referer") or "/").split("?")[0]
            return self.redirect(urllib.parse.urlparse(back).path or "/", f"failed: {err}")

    def manage(self, path, form, user):
        if path == "/-/settings":
            values = {name: form.get(name, "").strip() for name, _ in FIELDS}
            values = {k: v for k, v in values.items() if v and not re.search(r"\s", v)}
            if values:
                save_secrets(values)
            return self.redirect("/-/settings", f"saved {len(values)}; nixbot restarts with them" if values else "nothing changed")
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
            return self.redirect("/", f"added {name}; nixbot restarts and checks it now")
        parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/")]
        if parts[:2] == ["-", "repo"] and len(parts) >= 6 and all(SEGMENT.fullmatch(p) for p in parts[2:5]):
            forge, owner, name, rest = parts[2], parts[3], parts[4], parts[5:]
            back = f"/-/repo/{forge}/{quote(owner)}/{quote(name)}"
            if rest == ["remove"]:
                repo = nixbot("GET", repo_path(forge, owner, name), user)
                if repo["enabled"]:
                    nixbot("POST", repo_path(forge, owner, name) + "/disable", user, raw=True)
                repos = load_repos()
                repos.pop(f"{owner}/{name}", None)
                save_repos(repos)
                return self.redirect("/", f"removed {owner}/{name}; its builds go once nixbot restarts")
            if rest == ["toggle"]:
                repo = nixbot("GET", repo_path(forge, owner, name), user)
                nixbot("POST", repo_path(forge, owner, name) + ("/disable" if repo["enabled"] else "/enable"), user, raw=True)
                return self.redirect("/", f"{owner}/{name} {'disabled' if repo['enabled'] else 'enabled'}")
            if rest[0].isdigit() and rest[1:] in (["restart"], ["cancel"]):
                nixbot("POST", repo_path(forge, owner, name) + f"/builds/{rest[0]}/{rest[1]}", user, raw=True)
                return self.redirect(f"{back}/{rest[0]}", f"build #{rest[0]}: {rest[1]} sent")
            if rest[0].isdigit() and len(rest) == 4 and rest[1] == "attr" and rest[3] == "restart":
                nixbot("POST", repo_path(forge, owner, name) + f"/builds/{rest[0]}/attrs/{quote(rest[2])}/restart", user, raw=True)
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


if __name__ == "__main__" and sys.argv[1:2] == ["user"]:
    users_cli(sys.argv[2:])
elif __name__ == "__main__":
    # The machines file matches the saved state (or the seed) from the first start.
    save(load())
    ThreadingHTTPServer(("127.0.0.1", 8091), Handler).serve_forever()
