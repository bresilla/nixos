"""CI settings and builders page.

Settings: the secrets nixbot runs with (gitea token, OAuth app, attic token),
saved under /var/lib/ci/secrets; saving restarts nixbot. The first visit sets the
admin password, which every later visit needs.

Builders: machines are reached over SSH (ssh-ng, user nix-ssh) with the
container's own key; each system points at one machine. Saving writes
/var/lib/ci/machines, which the Nix daemon reads afresh for every remote build,
so a change applies to the next build without a restart.
"""
import base64
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = "/var/lib/ci-builders/builders.json"
ADMIN = "/var/lib/ci-builders/admin.json"
SECRETS = "/var/lib/ci/secrets"
# Settings fields: file name, label, whether its value is shown back.
FIELDS = [
    ("gitea-token", "gitea token of the nixbot user (issue, repository: read and write; user: read)", False),
    ("gitea-oauth-id", "client ID of gitea's nixbot OAuth app", True),
    ("gitea-oauth-secret", "client secret of that OAuth app", False),
    ("attic-token", "attic token that may push to the bresilla cache", False),
]
MACHINES = "/var/lib/ci/machines"
KEY = "/var/lib/ci/builder_ed25519"
BASE = "/builders"
THEME = os.environ.get("CI_THEME", "/_bresilla")
SYSTEMS = os.environ.get("CI_SYSTEMS", "").split()
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
SYSTEM = re.compile(r"[a-z0-9_]+-[a-z]+")
ADDRESS = re.compile(r"[A-Za-z0-9.:-]{1,253}")
HOST_KEY = re.compile(r"ssh-(ed25519|rsa) [A-Za-z0-9+/=]{20,800}")
FEATURES = re.compile(r"[a-z0-9,-]{0,200}")
sessions = {}
results = {}
lock = threading.Lock()


# Saved state: machines by name, and the machine each system builds on.

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


# Checks run in the background; the page shows the last result of each.

def store_url(m):
    url = f"ssh-ng://{m['user']}@{m['address']}?ssh-key={KEY}"
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


# The admin password: set once on the first visit, scrypt-hashed.

def password_hash(password, salt):
    return hashlib.scrypt(password.encode(), salt=salt, n=2 ** 15, r=8, p=1, maxmem=2 ** 26).hex()


def admin_set():
    return os.path.exists(ADMIN)


def set_admin(password):
    salt = secrets.token_bytes(16)
    tmp = ADMIN + ".new"
    with open(tmp, "w") as f:
        json.dump({"salt": salt.hex(), "hash": password_hash(password, salt)}, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, ADMIN)


def check_admin(password):
    with open(ADMIN) as f:
        saved = json.load(f)
    return hmac.compare_digest(password_hash(password, bytes.fromhex(saved["salt"])), saved["hash"])


# Secrets: written one file each, then a touch of "saved" restarts nixbot.

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


# Pages.

def esc(s):
    return html.escape(str(s), quote=True)


def result(key):
    with lock:
        text, at = results.get(key, ("", ""))
    if not text:
        return '<span class=mute>not checked</span>'
    cls = "ok" if not text.startswith("failed") and text != "running" else ("run" if text == "running" else "bad")
    return f'<span class={cls}>{esc(text)}</span> <span class=mute>{esc(at)}</span>'


def page(body, flash=""):
    return f"""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1"><title>builders</title>
<link rel=stylesheet href="/static/style.css"><link rel=stylesheet href="{THEME}/theme.css">
<script src="{THEME}/theme.js"></script><style>
main {{ display: block; max-width: 70rem; margin: 0 auto; padding: 1.25rem; }}
table {{ width: 100%; border-collapse: collapse; margin: .5rem 0 1.5rem; }}
th, td {{ text-align: left; padding: .45rem .5rem; border-bottom: 1px solid var(--border); vertical-align: middle; }}
input, select, button {{ font: inherit; padding: .3rem .5rem; border: 1px solid var(--border); border-radius: 6px;
  background: var(--bg); color: var(--fg); }}
button {{ cursor: pointer; background: var(--accent); color: #fff; border-color: var(--accent); }}
button.ghost {{ background: transparent; color: var(--accent); }}
button.danger {{ background: transparent; color: var(--bad); border-color: var(--bad); }}
form {{ display: inline; }} .row {{ display: flex; gap: .5rem; flex-wrap: wrap; align-items: center; }}
.mute {{ color: var(--muted); font-size: .85em; }} .ok {{ color: var(--ok); }} .bad {{ color: var(--bad); }}
.run {{ color: var(--run); }} code {{ overflow-wrap: anywhere; }}
.flash {{ border-left: 3px solid var(--accent); padding: .5rem .75rem; margin: 0 0 1rem;
  background: color-mix(in srgb, var(--accent) 12%, transparent); }}
</style></head><body><header><h1><a href="/">nixbot</a></h1><a href="/builds">builds</a>
<a href="{BASE}">builders</a><a href="{BASE}/settings">settings</a><span class=header-spacer></span></header><main>
{f'<div class=flash>{esc(flash)}</div>' if flash else ''}{body}</main></body></html>"""


def setup_page(flash=""):
    return page(f"""<h2>set up</h2><p>Choose the admin password for CI settings and builders.
Whoever saves it first owns this page, so do it now.</p>
<form method=post action="{BASE}/setup" class=row>
<input type=password name=password placeholder="password, 12+ characters" minlength=12 required autofocus>
<input type=password name=again placeholder="again" minlength=12 required><button>save</button></form>""", flash)


def login_page(flash=""):
    return page(f"""<h2>sign in</h2>
<form method=post action="{BASE}/login" class=row><input type=password name=password placeholder=password required autofocus>
<button>sign in</button></form>""", flash)


def settings_page(flash=""):
    rows = ""
    for name, label, shown in FIELDS:
        value = secret_value(name)
        if shown:
            field = f'<input name="{name}" value="{esc(value)}" size=40>'
        else:
            field = f'<input type=password name="{name}" placeholder="{"set; type to replace" if value else "not set"}" size=40 autocomplete=off>'
        state = '<span class=ok>set</span>' if value else '<span class=bad>not set</span>'
        rows += f"<tr><td>{esc(label)}</td><td>{field}</td><td>{state}</td></tr>"
    return page(f"""<h2>settings</h2><p>nixbot is <b>{esc(nixbot_state())}</b>. Saving restarts it with these;
an empty field keeps what is saved.</p>
<p class=mute>Gitea token: log in as nixbot, Settings → Applications → Access Tokens. OAuth app: your Settings →
Applications → OAuth2, redirect <code>https://build.bresilla.com/auth/gitea/callback</code>. Attic token:
cache.bresilla.com → bresilla → settings → auth tokens, pull and push.</p>
<form method=post action="{BASE}/settings"><table><tr><th>what</th><th>value</th><th></th></tr>{rows}</table>
<button>save and restart nixbot</button></form>""", flash)


def main_page(state, flash=""):
    machines = state["machines"]

    def options(chosen):
        return "".join(f'<option value="{esc(n)}"{" selected" if n == chosen else ""}>{esc(n)}</option>'
                       for n in sorted(machines))
    rows = ""
    for system in sorted(set(state["systems"]) | set(SYSTEMS)):
        on = state["systems"].get(system, "")
        rows += (f'<tr><td><code>{esc(system)}</code></td><td><form method=post action="{BASE}/system" class=row>'
                 f'<input type=hidden name=system value="{esc(system)}"><select name=machine>'
                 f'<option value="">nobody</option>{options(on)}</select><button class=ghost>set</button></form></td>'
                 f'<td>{result("system:" + system)}</td><td><form method=post action="{BASE}/test">'
                 f'<input type=hidden name=system value="{esc(system)}"><button class=ghost>test build</button></form></td></tr>')
    mrows = ""
    for name, m in sorted(machines.items()):
        key = m.get("hostKey") or ""
        mrows += f"""<tr><td><b>{esc(name)}</b></td><td colspan=5><form method=post action="{BASE}/machine" class=row>
<input type=hidden name=name value="{esc(name)}">
<input name=address value="{esc(m['address'])}" size=14 title=address>
<input name=user value="{esc(m['user'])}" size=7 title="ssh user">
<input name=jobs value="{esc(m['jobs'])}" size=2 title="parallel jobs">
<input name=speed value="{esc(m['speed'])}" size=2 title="speed factor">
<input name=features value="{esc(m['features'])}" size=28 title="features">
<label><input type=checkbox name=enabled{' checked' if m.get('enabled', True) else ''}> on</label>
<button class=ghost>save</button></form>
<div class=mute>host key: <code>{esc(key[:24] + '…' if key else 'none, fetch it')}</code></div></td>
<td>{result("machine:" + name)}<div class=row>
<form method=post action="{BASE}/check"><input type=hidden name=name value="{esc(name)}"><button class=ghost>check</button></form>
<form method=post action="{BASE}/hostkey"><input type=hidden name=name value="{esc(name)}"><button class=ghost>fetch key</button></form>
<form method=post action="{BASE}/remove" onsubmit="return confirm('Remove {esc(name)}?')">
<input type=hidden name=name value="{esc(name)}"><button class=danger>remove</button></form></div></td></tr>"""
    return page(f"""<h2>systems</h2><p class=mute>Each system builds on one machine; the next build uses a change here.</p>
<table><tr><th>system</th><th>builds on</th><th>last test</th><th></th></tr>{rows}</table>
<form method=post action="{BASE}/system" class=row><input name=system placeholder="new system, e.g. riscv64-linux" required>
<select name=machine><option value="">nobody</option>{options('')}</select><button>add system</button></form>
<h2>machines</h2><p class=mute>Reached over SSH as nix-ssh with this container's key; a new machine needs that key
in its <code>serveBuilds</code> clients and a <code>ciBuilder.address</code> on cicd0.</p>
<table><tr><th>name</th><th colspan=5>settings</th><th>status</th></tr>{mrows}</table>
<form method=post action="{BASE}/machine" class=row><input name=name placeholder=name required size=8>
<input name=address placeholder="address, e.g. 10.77.0.10" required><input name=user value=nix-ssh size=7>
<input name=jobs value=4 size=2><input name=speed value=1 size=2>
<input name=features value="big-parallel,kvm,nixos-test,benchmark" size=28>
<input type=hidden name=enabled value=on><button>add machine</button></form>
<p><form method=post action="{BASE}/logout"><button class=ghost>sign out</button></form></p>""", flash)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply(self, code, body, headers=()):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, flash="", headers=(), to=BASE):
        self.send_response(303)
        self.send_header("Location", to + ("?m=" + urllib.parse.quote(flash) if flash else ""))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()

    def session(self):
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "ci_builders" and sessions.get(v, 0) > time.time():
                return v
        return None

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        flash = urllib.parse.parse_qs(url.query).get("m", [""])[0]
        path = url.path.rstrip("/")
        if path not in (BASE, BASE + "/settings"):
            return self.reply(404, page("not found"))
        if not admin_set():
            return self.reply(200, setup_page(flash))
        if not self.session():
            return self.reply(200, login_page(flash))
        if path == BASE + "/settings":
            return self.reply(200, settings_page(flash))
        return self.reply(200, main_page(load(), flash))

    def sign_in(self, to):
        sid = secrets.token_urlsafe(32)
        sessions[sid] = time.time() + 14 * 86400
        return self.redirect(to=to, headers=[
            ("Set-Cookie", f"ci_builders={sid}; Path={BASE}; HttpOnly; Secure; SameSite=Strict; Max-Age=1209600")])

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        length = min(int(self.headers.get("Content-Length", 0)), 65536)
        form = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(length).decode()).items()}
        # Forms only from this site; the session cookie is also SameSite=Strict.
        origin = self.headers.get("Origin")
        if origin and urllib.parse.urlparse(origin).netloc != self.headers.get("Host"):
            return self.reply(403, page("cross-site request refused"))
        if path == BASE + "/setup":
            if admin_set():
                return self.redirect("already set up; sign in")
            password = form.get("password", "")
            if len(password) < 12 or password != form.get("again"):
                return self.reply(400, setup_page("12+ characters, typed the same twice"))
            set_admin(password)
            return self.sign_in(BASE + "/settings")
        if path == BASE + "/login":
            if not admin_set() or not check_admin(form.get("password", "")):
                time.sleep(1)
                return self.reply(401, login_page("wrong password"))
            return self.sign_in(BASE)
        sid = self.session()
        if not sid:
            return self.redirect("sign in first")
        if path == BASE + "/settings":
            values = {name: form.get(name, "").strip() for name, _, _ in FIELDS}
            values = {k: v for k, v in values.items() if v and not re.search(r"\s", v)}
            if values:
                save_secrets(values)
            return self.redirect(f"saved {len(values)}; nixbot restarts with them" if values else "nothing changed",
                                 to=BASE + "/settings")
        if path == BASE + "/logout":
            sessions.pop(sid, None)
            return self.redirect(headers=[("Set-Cookie", f"ci_builders=; Path={BASE}; Max-Age=0")])
        state = load()
        name = form.get("name", "")
        if path == BASE + "/system":
            system, machine = form.get("system", ""), form.get("machine", "")
            if not SYSTEM.fullmatch(system) or (machine and machine not in state["machines"]):
                return self.redirect("systems look like x86_64-linux")
            state["systems"][system] = machine
            save(state)
            return self.redirect(f"{system} builds on {machine or 'nobody'}")
        if path == BASE + "/test":
            system = form.get("system", "")
            if SYSTEM.fullmatch(system):
                test_system(system)
            return self.redirect(f"test build for {system} started; reload in a moment")
        if path == BASE + "/machine":
            m = {"address": form.get("address", ""), "user": form.get("user", "nix-ssh"),
                 "jobs": form.get("jobs", "4"), "speed": form.get("speed", "1"),
                 "features": form.get("features", ""), "enabled": form.get("enabled") == "on"}
            valid = (NAME.fullmatch(name) and ADDRESS.fullmatch(m["address"]) and NAME.fullmatch(m["user"])
                     and m["jobs"].isdigit() and m["speed"].isdigit() and FEATURES.fullmatch(m["features"]))
            if not valid:
                return self.redirect("names: a-z 0-9 -; jobs and speed: numbers")
            m["jobs"], m["speed"] = int(m["jobs"]), int(m["speed"])
            m["hostKey"] = state["machines"].get(name, {}).get("hostKey", "")
            if m["hostKey"] and state["machines"][name]["address"] != m["address"]:
                m["hostKey"] = ""
            state["machines"][name] = m
            save(state)
            return self.redirect(f"saved {name}" + ("" if m["hostKey"] else "; fetch its host key next"))
        if name not in state["machines"]:
            return self.redirect("no such machine")
        if path == BASE + "/remove":
            del state["machines"][name]
            state["systems"] = {s: (n if n != name else "") for s, n in state["systems"].items()}
            save(state)
            return self.redirect(f"removed {name}")
        if path == BASE + "/check":
            check_machine(name, state["machines"][name])
            return self.redirect(f"checking {name}; reload in a moment")
        if path == BASE + "/hostkey":
            key = fetch_host_key(state["machines"][name]["address"])
            if not key or not HOST_KEY.fullmatch(key):
                return self.redirect(f"{name} did not answer with an ed25519 host key")
            state["machines"][name]["hostKey"] = key
            save(state)
            return self.redirect(f"saved {name}'s host key {key[:40]}…")
        return self.reply(404, page("not found"))


if __name__ == "__main__":
    # The machines file matches the saved state (or the seed) from the first start.
    save(load())
    ThreadingHTTPServer(("127.0.0.1", 8091), Handler).serve_forever()
