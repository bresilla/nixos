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
import getpass
import hashlib
import hmac
import html
import json
import os
import pwd
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = "/var/lib/ci-builders/builders.json"
USERS = "/var/lib/ci-builders/users.json"
USER_NAME = re.compile(r"[a-z0-9_-]{1,32}")
SESSION_DAYS = 14
SECRETS = "/var/lib/ci/secrets"
# Settings fields: file name, label, whether its value is shown back.
FIELDS = [
    ("gitea-token", "gitea token of the nixbot user (issue, repository: read and write; user: read)", False),
    ("attic-token", "attic token that may push to the bresilla cache", False),
]
MACHINES = "/var/lib/ci/machines"
KEY = "/var/lib/ci/builder_ed25519"
BASE = "/builders"
THEME = os.environ.get("CI_THEME", "/_bresilla")
V = "?v=" + os.environ.get("CI_THEME_VERSION", "0")
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


# Accounts, as on the cache UI: made on hive with `sudo ci-user add|remove|list`,
# scrypt-hashed, and one sign-in for the whole site (nixbot trusts it too).

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


# Pages, in the cache UI's layout: header with the logo and nav, then sections.

ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{}</svg>'
ICONS = {
    "builders": ICON.format('<rect x="3" y="4" width="18" height="6" rx="1"/><rect x="3" y="14" width="18" height="6" rx="1"/><path d="M7 7h.01M7 17h.01"/>'),
    "settings": ICON.format('<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/>'),
}


def logo():
    with open(os.environ["CI_LOGO"]) as f:
        return re.sub(r'fill="#[0-9a-fA-F]+"', 'fill="currentColor"', f.read().split("?>", 1)[-1])


def esc(s):
    return html.escape(str(s), quote=True)


def result(key):
    with lock:
        text, at = results.get(key, ("", ""))
    if not text:
        return '<span class=mute>not checked</span>'
    cls = "run" if text == "running" else ("bad" if text.startswith("failed") else "ok")
    return f'<span class={cls}>{esc(text)}</span> <span class=mute>{esc(at)}</span>'


def page(title, body, flash="", nav="", user=None):
    links = [("builds", "/", "Builds")] + ([("builders", BASE, "Builders"), ("settings", BASE + "/settings", "Settings")]
                                           if user else [])
    nav_html = "".join(f'<a href="{h}" class="{"on" if k == nav else ""}">{label}</a>' for k, h, label in links)
    if user:
        right = (f'<span class=mute>{esc(user)}</span><form class=inline method=post action="{BASE}/logout">'
                 f'<button class="ghost small">Sign out</button></form>')
    else:
        right = f'<a href="{BASE}/login"><button class=small>Sign in</button></a>'
    note = f'<div class=flash>{esc(flash)}</div>' if flash else ""
    return f"""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1"><title>{esc(title)}</title>
<link rel=icon href="{THEME}/logo.svg{V}"><link rel=stylesheet href="{THEME}/ui.css{V}"><script src="{THEME}/theme.js{V}"></script>
</head><body><header>{logo()}<a href="/">build</a><nav>{nav_html}</nav><div class=who>{right}</div></header>
<main>{note}{body}</main></body></html>"""


def head(icon, title, summary):
    return f'<div class=pagehead><div><h1>{ICONS[icon]}{esc(title)}</h1><div class=summary>{summary}</div></div></div>'


def login_page(flash=""):
    hint = "" if load_users() else '<p class=mute>No accounts yet: make one on hive with <code>sudo ci-user add &lt;name&gt;</code>.</p>'
    return page("sign in", f"""<div class=pagehead><h1>Sign in</h1></div>{hint}
<form method=post action="{BASE}/login" class=card style="max-width:360px">
<p><input class=wide name=user placeholder=user autocomplete=username required autofocus></p>
<p><input class=wide type=password name=password placeholder=password autocomplete=current-password required></p>
<button>sign in</button></form>""", flash)


def settings_page(user, flash=""):
    rows = ""
    for name, label, shown in FIELDS:
        value = secret_value(name)
        if shown:
            field = f'<input name="{name}" value="{esc(value)}" class=wide>'
        else:
            field = (f'<input type=password name="{name}" class=wide autocomplete=off '
                     f'placeholder="{"saved; type to replace" if value else "not set"}">')
        state = '<span class=ok>saved</span>' if value else '<span class=bad>missing</span>'
        rows += f"<tr><td>{esc(label)}</td><td>{field}</td><td class=num>{state}</td></tr>"
    state = nixbot_state()
    cls = "ok" if state == "active" else "bad"
    return page("settings", f"""{head("settings", "Settings", f'nixbot is <span class={cls}>{esc(state)}</span>')}
<section class=set><h3>secrets</h3><div>
<p class=mute>Saving restarts nixbot with them; an empty field keeps what is saved, and nothing saved is shown again.</p>
<form method=post action="{BASE}/settings"><table><tr><th>what</th><th>value</th><th></th></tr>{rows}</table>
<p><button>Save and restart nixbot</button></p></form></div></section>
<section class=set><h3>where they come from</h3><div><table>
<tr><td>gitea token</td><td>log in to git.bresilla.com as <b>nixbot</b> → Settings → Applications → Access Tokens:
issue and repository read and write, user read</td></tr>
<tr><td>attic token</td><td>cache.bresilla.com → Settings → auth tokens, all caches: name <code>ci</code>, pull and push</td></tr>
</table></div></section>""", flash, "settings", user)


def main_page(state, user, flash=""):
    machines = state["machines"]

    def options(chosen):
        return "".join(f'<option value="{esc(n)}"{" selected" if n == chosen else ""}>{esc(n)}</option>'
                       for n in sorted(machines))
    rows = ""
    for system in sorted(set(state["systems"]) | set(SYSTEMS)):
        on = state["systems"].get(system, "")
        rows += (f'<tr><td><code>{esc(system)}</code></td><td><form method=post action="{BASE}/system" class=row>'
                 f'<input type=hidden name=system value="{esc(system)}"><select name=machine>'
                 f'<option value="">nobody</option>{options(on)}</select><button class="ghost small">Set</button></form></td>'
                 f'<td>{result("system:" + system)}</td><td class=num><form method=post action="{BASE}/test" class=inline>'
                 f'<input type=hidden name=system value="{esc(system)}"><button class="ghost small">Test build</button></form></td></tr>')
    cards = ""
    for name, m in sorted(machines.items()):
        key = m.get("hostKey") or ""
        used = ", ".join(s for s, n in sorted(state["systems"].items()) if n == name) or "nothing yet"
        cards += f"""<div class=card><div class=title><b>{esc(name)}</b><span>{result("machine:" + name)}</span></div>
<div class=mute>builds {esc(used)} · host key <code>{esc(key[:28] + '…' if key else 'none, fetch it')}</code></div>
<form method=post action="{BASE}/machine" class=row><input type=hidden name=name value="{esc(name)}">
<input name=address value="{esc(m['address'])}" size=14 title=address>
<input name=user value="{esc(m['user'])}" size=8 title="ssh user">
<input name=jobs value="{esc(m['jobs'])}" size=3 title="parallel jobs">
<input name=speed value="{esc(m['speed'])}" size=3 title="speed factor">
<input name=features value="{esc(m['features'])}" size=30 title=features>
<label><input type=checkbox name=enabled{' checked' if m.get('enabled', True) else ''}> on</label>
<button class=small>Save</button></form>
<div class=row><form method=post action="{BASE}/check" class=inline><input type=hidden name=name value="{esc(name)}">
<button class="ghost small">Check</button></form>
<form method=post action="{BASE}/hostkey" class=inline><input type=hidden name=name value="{esc(name)}">
<button class="ghost small">Fetch host key</button></form>
<form method=post action="{BASE}/remove" class=inline onsubmit="return confirm('Remove {esc(name)}?')">
<input type=hidden name=name value="{esc(name)}"><button class="danger small">Remove</button></form></div></div>"""
    summary = f"{len(machines)} machines · {sum(1 for n in state['systems'].values() if n)} systems assigned"
    return page("builders", f"""{head("builders", "Builders", summary)}
<section class=set><h3>systems</h3><div><p class=mute>Each system builds on one machine; the next build uses a change here.</p>
<table><tr><th>system</th><th>builds on</th><th>last test</th><th></th></tr>{rows}</table>
<form method=post action="{BASE}/system" class=row><input name=system placeholder="new system, e.g. riscv64-linux" required>
<select name=machine><option value="">nobody</option>{options('')}</select><button>Add system</button></form></div></section>
<section class=set><h3>machines</h3><div><p class=mute>Reached over SSH as nix-ssh with this container's key, on cicd0.
A new machine needs that key in its <code>serveBuilds</code> clients and a <code>ciBuilder.address</code>.</p>
{cards or '<div class=empty>no machines yet</div>'}
<form method=post action="{BASE}/machine" class=row><input name=name placeholder=name required size=8>
<input name=address placeholder="address, e.g. 10.77.0.10" required><input name=user value=nix-ssh size=8>
<input name=jobs value=4 size=3><input name=speed value=1 size=3>
<input name=features value="big-parallel,kvm,nixos-test,benchmark" size=30>
<input type=hidden name=enabled value=on><button>Add machine</button></form></div></section>""", flash, "builders", user)


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
        """The signed-in user and session id, if the cookie names a live session of a current account."""
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            user, expires = sessions.get(v, (None, 0)) if k == "ci_session" else (None, 0)
            if user and expires > time.time() and user in load_users():
                return user, v
        return None, None

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        flash = urllib.parse.parse_qs(url.query).get("m", [""])[0]
        path = url.path.rstrip("/")
        user, _ = self.session()
        # nginx asks here before every nixbot request; nixbot trusts the name it gets.
        if path == BASE + "/_auth":
            self.send_response(200)
            self.send_header("X-Remote-User", user or "")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == BASE + "/login" or (path in (BASE, BASE + "/settings") and not user):
            return self.reply(200, login_page(flash))
        if path == BASE + "/settings":
            return self.reply(200, settings_page(user, flash))
        if path == BASE:
            return self.reply(200, main_page(load(), user, flash))
        return self.reply(404, page("not found", "<div class=empty>not found</div>", user=user))

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        length = min(int(self.headers.get("Content-Length", 0)), 65536)
        form = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(length).decode()).items()}
        # Forms only from this site; the session cookie is also SameSite=Strict.
        origin = self.headers.get("Origin")
        if origin and urllib.parse.urlparse(origin).netloc != self.headers.get("Host"):
            return self.reply(403, page("refused", "<div class=empty>cross-site request refused</div>"))
        if path == BASE + "/login":
            name = form.get("user", "")
            if not USER_NAME.fullmatch(name) or not check_login(name, form.get("password", "")):
                time.sleep(1)
                return self.reply(401, login_page("wrong user or password"))
            sid = secrets.token_urlsafe(32)
            sessions[sid] = (name, time.time() + SESSION_DAYS * 86400)
            return self.redirect(f"signed in as {name}", to="/", headers=[
                ("Set-Cookie", f"ci_session={sid}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age={SESSION_DAYS * 86400}")])
        user, sid = self.session()
        if not user:
            return self.redirect("sign in first", to=BASE + "/login")
        if path == BASE + "/logout":
            sessions.pop(sid, None)
            return self.redirect("signed out", to="/", headers=[("Set-Cookie", "ci_session=; Path=/; Max-Age=0")])
        if path == BASE + "/settings":
            values = {name: form.get(name, "").strip() for name, _, _ in FIELDS}
            values = {k: v for k, v in values.items() if v and not re.search(r"\s", v)}
            if values:
                save_secrets(values)
            return self.redirect(f"saved {len(values)}; nixbot restarts with them" if values else "nothing changed",
                                 to=BASE + "/settings")
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
        return self.reply(404, page("not found", "<div class=empty>not found</div>"))


if __name__ == "__main__" and sys.argv[1:2] == ["user"]:
    users_cli(sys.argv[2:])
elif __name__ == "__main__":
    # The machines file matches the saved state (or the seed) from the first start.
    save(load())
    ThreadingHTTPServer(("127.0.0.1", 8091), Handler).serve_forever()
