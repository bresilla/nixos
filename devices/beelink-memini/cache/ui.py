"""Cache page over Attic: public caches for everyone; signed-in accounts manage them.

GET /-/pins answers like app.cachix.org/api/v1/cache/<name>/pin; CI sets a pin
with PUT /-/pins/<name> (body: the store path) and the pin token.
Accounts live in their own database: `cache-ui-user add|remove|list [name]` on nest.
"""

import base64
import getpass
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import shlex
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

env = os.environ.get
DB = env("CACHE_DB", "")
UI_DB = env("CACHE_UI_DB", "")
URL = env("CACHE_URL", "").rstrip("/")
PINS = env("CACHE_PINS_FILE", "")
PIN_TOKEN = env("CACHE_PIN_TOKEN", "")
API = env("CACHE_API", "http://127.0.0.1:8081")
ATTICADM = shlex.split(env("CACHE_ATTICADM", ""))
GC = shlex.split(env("CACHE_GC", ""))
MAIN_PINS = "https://raw.githubusercontent.com/bresilla/nixos/main/packages/pins.json"
PIN_NAME = re.compile(r"[A-Za-z0-9._+-]{1,100}")
CACHE_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,49}")
USER_NAME = re.compile(r"[a-z0-9_-]{1,32}")
STORE_PATH = re.compile(r"/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+?=-]+")
SESSION_DAYS = 14
pins_lock = threading.Lock()
gc_state = {"running": False, "last": "not run since the page started"}

STYLE = """
:root { --accent: hsl(210 65% 50%); color-scheme: light dark; }
@media (prefers-color-scheme: light) { :root { --bg: #ffffff; --fg: #1a1a1a; --mute: #6b7280; --tint: 5%; } }
@media (prefers-color-scheme: dark) { :root { --bg: #1e1f20; --fg: #f2f2f2; --mute: #9ca3af; --tint: 8%; } }
body { margin: 0; font: 14px/1.5 "Goku", monospace; color: var(--fg);
  background: color-mix(in srgb, var(--accent) var(--tint), var(--bg)); }
header { display: flex; align-items: center; gap: 12px; padding: 10px 20px;
  background: color-mix(in srgb, var(--accent) calc(var(--tint) * 2.5), var(--bg));
  border-bottom: 2px solid var(--accent); }
header svg { width: 30px; height: 30px; color: var(--fg); }
header a { color: inherit; text-decoration: none; font-size: 18px; }
header .who { margin-left: auto; display: flex; gap: 10px; align-items: center; }
header .who a, header .who button { font-size: 14px; }
main { max-width: 1000px; margin: 0 auto; padding: 20px; }
h2 { font-size: 15px; color: var(--accent); margin: 28px 0 8px; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid color-mix(in srgb, var(--accent) 25%, transparent); }
th { color: var(--mute); font-weight: normal; }
.num { text-align: right; white-space: nowrap; }
code, pre { background: color-mix(in srgb, var(--accent) 12%, transparent); padding: 1px 5px; border-radius: 4px; word-break: break-all; }
pre { padding: 10px; white-space: pre-wrap; margin: 0; }
.mute { color: var(--mute); }
input, select { font: inherit; color: inherit; box-sizing: border-box; padding: 7px 10px; border-radius: 6px;
  border: 1px solid color-mix(in srgb, var(--accent) 40%, transparent); background: transparent; outline-color: var(--accent); }
input.wide { width: 100%; }
button { font: inherit; cursor: pointer; padding: 7px 12px; border-radius: 6px; color: #fff; background: var(--accent);
  border: 1px solid var(--accent); }
button.ghost { background: transparent; color: var(--accent); }
button.danger { background: transparent; color: #d33; border-color: #d33; }
button.small { padding: 2px 8px; }
form.row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin: 8px 0; }
form.inline { display: inline; margin: 0; }
.card { border: 1px solid color-mix(in srgb, var(--accent) 25%, transparent); border-radius: 8px; padding: 12px 14px; margin: 10px 0;
  background: color-mix(in srgb, var(--accent) calc(var(--tint) * 1.5), var(--bg)); }
.pill { font-size: 12px; padding: 1px 8px; border-radius: 10px; border: 1px solid var(--accent); color: var(--accent); }
.flash { border-left: 3px solid var(--accent); padding: 8px 12px; margin: 10px 0;
  background: color-mix(in srgb, var(--accent) 12%, transparent); }
.stats { display: flex; gap: 24px; flex-wrap: wrap; }
.stats div b { display: block; font-size: 18px; color: var(--accent); }
a { color: var(--accent); }
::selection { background: color-mix(in srgb, var(--accent) 40%, transparent); }
"""

# Same rule as gitea: a new hue on refresh, the saved one while clicking around.
SCRIPT = """
const reload = performance.getEntriesByType("navigation")[0]?.type === "reload";
let hue = localStorage.getItem("accent-hue");
if (reload || hue === null) { hue = Math.floor(Math.random() * 360); localStorage.setItem("accent-hue", hue); }
document.documentElement.style.setProperty("--accent", `hsl(${hue} 65% 50%)`);
document.addEventListener("click", (event) => {
  const id = event.target.dataset?.copy;
  if (!id) return;
  const text = document.getElementById(id).textContent;
  navigator.clipboard?.writeText(text).then(() => { event.target.textContent = "copied"; },
    () => getSelection().selectAllChildren(document.getElementById(id)));
});
"""


def logo():
    with open(env("CACHE_LOGO")) as f:
        return re.sub(r'fill="#[0-9a-fA-F]+"', 'fill="currentColor"', f.read().split("?>", 1)[-1])


def size(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def when(stamp):
    return (stamp or "-")[:16].replace("T", " ")


def public_key(keypair):
    # The stored keypair holds the secret; only its public half is ever shown.
    name, secret = keypair.split(":", 1)
    return f"{name}:{base64.b64encode(base64.b64decode(secret)[32:]).decode()}"


def query(sql, args=()):
    with sqlite3.connect(f"file:{DB}?mode=ro", uri=True) as db:
        return db.execute(sql, args).fetchall()


def write(sql, args=()):
    with sqlite3.connect(DB, timeout=15) as db:
        db.execute("PRAGMA foreign_keys = ON")
        return db.execute(sql, args).rowcount


# Accounts and sessions, separate from Attic's database.

def ui_db():
    db = sqlite3.connect(UI_DB, timeout=10)
    db.execute("CREATE TABLE IF NOT EXISTS users (name TEXT PRIMARY KEY, salt BLOB, hash BLOB, created TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS sessions (token TEXT PRIMARY KEY, user TEXT, csrf TEXT, expires REAL)")
    return db


def password_hash(password, salt):
    return hashlib.scrypt(password.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)


def check_login(name, password):
    with ui_db() as db:
        row = db.execute("SELECT salt, hash FROM users WHERE name = ?", (name,)).fetchone()
    # Hash even for unknown names, so timing doesn't tell which names exist.
    salt, stored = row or (b"\0" * 16, b"\0" * 32)
    return row is not None and hmac.compare_digest(password_hash(password, salt), stored)


def new_session(name):
    token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(16)
    with ui_db() as db:
        db.execute("DELETE FROM sessions WHERE expires < ?", (time.time(),))
        db.execute("INSERT INTO sessions VALUES (?, ?, ?, ?)", (token, name, csrf, time.time() + SESSION_DAYS * 86400))
    return token


def session(token):
    if not token:
        return None
    with ui_db() as db:
        row = db.execute("SELECT user, csrf FROM sessions WHERE token = ? AND expires > ?", (token, time.time())).fetchone()
    return {"user": row[0], "csrf": row[1], "token": token} if row else None


def users_cli(args):
    action, name = (args + [None, None])[:2]
    with ui_db() as db:
        if action == "list":
            for (user,) in db.execute("SELECT name FROM users ORDER BY name"):
                print(user)
        elif action == "add" and name and USER_NAME.fullmatch(name):
            password = getpass.getpass(f"password for {name}: ")
            if len(password) < 10 or password != getpass.getpass("again: "):
                sys.exit("passwords differ or are shorter than 10 characters")
            salt = secrets.token_bytes(16)
            db.execute("INSERT OR REPLACE INTO users VALUES (?, ?, ?, ?)",
                       (name, salt, password_hash(password, salt), datetime.now(timezone.utc).isoformat()))
            print(f"{name}: saved")
        elif action == "remove" and name:
            db.execute("DELETE FROM users WHERE name = ?", (name,))
            db.execute("DELETE FROM sessions WHERE user = ?", (name,))
            print(f"{name}: removed")
        else:
            sys.exit("usage: cache-ui-user add|remove <name> | list   (names: a-z 0-9 _ -)")


# Attic itself: an admin token minted per action, its API, garbage collection.

def make_token(sub, validity, perms):
    out = subprocess.run(ATTICADM + ["make-token", "--sub", sub, "--validity", validity] + perms,
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


def attic(method, path, body=None):
    perms = [f"--{p}=*" for p in ("pull", "push", "delete", "create-cache", "configure-cache",
                                  "configure-cache-retention", "destroy-cache")]
    request = urllib.request.Request(
        API + path, method=method, data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + make_token("cache-ui", "5m", perms), "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def run_gc():
    try:
        for passes in range(1, 201):
            subprocess.run(GC, capture_output=True, check=True)
            left = query("SELECT COUNT(*) FROM chunk WHERE state = 'D'")[0][0]
            gc_state["last"] = f"pass {passes} at {when(datetime.now().isoformat())}: {left} deleted chunks left"
            if left == 0:
                break
    except (subprocess.CalledProcessError, sqlite3.Error) as err:
        gc_state["last"] = f"failed: {err}"
    finally:
        gc_state["running"] = False


def start_gc():
    if not gc_state["running"]:
        gc_state["running"] = True
        threading.Thread(target=run_gc, daemon=True).start()


# Pins: the API's own file, plus the repo's packages/pins.json on main.

def read_pins():
    try:
        with open(PINS) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_pins(change):
    with pins_lock:
        pins = read_pins()
        change(pins)
        tmp = f"{PINS}.tmp"
        with open(tmp, "w") as f:
            json.dump(pins, f, indent=2, sort_keys=True)
        os.replace(tmp, PINS)


def set_pin(name, path):
    save_pins(lambda p: p.update({name: {"storePath": path, "updated": datetime.now(timezone.utc).isoformat()}}))


def pinned_paths():
    # Fails closed: without main's pins, nothing counts as unpinned.
    with urllib.request.urlopen(MAIN_PINS, timeout=15) as response:
        main = json.load(response)
    paths = {p for system in main.values() for p in system.values()}
    return paths | {p["storePath"] for p in read_pins().values()}


def systems():
    # Attic records no system; pin names say it, and dependencies take it from
    # the pinned package that references them.
    found = {}
    if env("CACHE_PINS"):
        with open(env("CACHE_PINS")) as f:
            for system, pins in json.load(f).items():
                for path in pins.values():
                    found[os.path.basename(path)] = system
    for name, pin in read_pins().items():
        for system in ("x86_64-linux", "aarch64-linux"):
            if name.endswith(f"-{system}"):
                found[os.path.basename(pin["storePath"])] = system
    for path, refs in query('SELECT store_path, "references" FROM object'):
        system = found.get(os.path.basename(path))
        for ref in json.loads(refs or "[]") if system else []:
            found.setdefault(os.path.basename(ref), system)
    return found


def cleanup(cache):
    # Unpinned, not needed by anything pinned, and older than a day (CI pins after pushing).
    keep = pinned_paths()
    rows = query('SELECT o.id, o.store_path, o."references", o.created_at FROM object o JOIN cache c ON c.id = o.cache_id '
                 "WHERE c.name = ?", (cache,))
    needed = {os.path.basename(r) for _, path, refs, _ in rows if path in keep for r in json.loads(refs or "[]")}
    cutoff = datetime.now(timezone.utc).timestamp() - 86400
    doomed = [i for i, path, _, created in rows
              if path not in keep and os.path.basename(path) not in needed
              and datetime.fromisoformat(created[:19]).replace(tzinfo=timezone.utc).timestamp() < cutoff]
    for object_id in doomed:
        write("DELETE FROM object WHERE id = ?", (object_id,))
    start_gc()
    return len(doomed)


# Pages.

def layout(title, body, who, flash=""):
    e = html.escape
    if who:
        right = (f'<span class=mute>{e(who["user"])}</span><form class=inline method=post action="/-/logout">'
                 f'<input type=hidden name=csrf value="{e(who["csrf"])}"><button class="ghost small">sign out</button></form>')
    else:
        right = '<a href="/-/login">sign in</a>'
    note = f'<div class=flash>{e(flash)}</div>' if flash else ""
    return f"""<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1"><title>{e(title)}</title>
<script>{SCRIPT}</script><style>{STYLE}</style></head><body>
<header>{logo()}<a href="/">cache</a><div class=who>{right}</div></header><main>{note}{body}</main></body></html>"""


def csrf_field(who):
    return f'<input type=hidden name=csrf value="{html.escape(who["csrf"])}">'


def visible_caches(who):
    return query(
        "SELECT c.name, c.keypair, c.is_public, COUNT(o.id), COALESCE(SUM(n.nar_size), 0), MAX(o.created_at) "
        "FROM cache c LEFT JOIN object o ON o.cache_id = c.id LEFT JOIN nar n ON n.id = o.nar_id "
        f"WHERE c.deleted_at IS NULL {'' if who else 'AND c.is_public'} GROUP BY c.id ORDER BY c.name")


def path_rows(where, args, who, deletable=None):
    e = html.escape
    arch = systems()
    rows = query(
        "SELECT c.name, o.store_path, n.nar_size, o.created_at "
        "FROM object o JOIN cache c ON c.id = o.cache_id JOIN nar n ON n.id = o.nar_id "
        f"WHERE c.deleted_at IS NULL {'' if who else 'AND c.is_public'} AND {where} "
        "ORDER BY o.created_at DESC LIMIT 200", args)
    out = []
    for cache, path, nar, created in rows:
        digest, _, pname = path.removeprefix("/nix/store/").partition("-")
        action = ""
        if deletable is not None:
            action = (f'<td class=num><form class=inline method=post action="/-/cache/{quote(cache)}/delete-path">'
                      f'{csrf_field(who)}<input type=hidden name=path value="{e(path)}">'
                      f'<button class="danger small" title="delete from the cache">delete</button></form></td>')
        out.append(
            f'<tr><td title="{e(path)}">{e(pname)} <span class=mute>{e(digest[:8])}</span></td>'
            f'<td><a href="/-/cache/{quote(cache)}">{e(cache)}</a></td>'
            f'<td class=mute>{e(arch.get(os.path.basename(path), ""))}</td><td class=num>{size(nar)}</td>'
            f'<td class=mute>{e(when(created))}</td>{action}</tr>')
    extra = "<th></th>" if deletable is not None else ""
    body = "".join(out) or f'<tr><td colspan={6 if extra else 5} class=mute>nothing found</td></tr>'
    return (f"<table><tr><th>path</th><th>cache</th><th>system</th><th class=num>size</th><th>pushed</th>{extra}</tr>"
            f"{body}</table>")


def overview(who, search, flash):
    e = html.escape
    caches = visible_caches(who)
    rows = "".join(
        f'<tr><td><a href="/-/cache/{quote(name)}">{e(name)}</a> '
        f'{"" if public else "<span class=pill>private</span>"}</td>'
        f'<td class=num>{count}</td><td class=num>{size(total)}</td><td class=mute>{e(when(last))}</td></tr>'
        for name, _, public, count, total, last in caches) or "<tr><td colspan=4 class=mute>no caches yet</td></tr>"
    body = (f"<h2>caches</h2><table><tr><th>name</th><th class=num>paths</th><th class=num>size</th>"
            f"<th>last push</th></tr>{rows}</table>")
    if who:
        stored = query("SELECT COALESCE(SUM(file_size), 0), COUNT(*) FROM chunk WHERE state = 'V'")[0]
        disk = shutil.disk_usage(os.path.dirname(DB))
        body = (f'<div class="card stats"><div><b>{size(stored[0])}</b>stored, compressed</div>'
                f'<div><b>{stored[1]}</b>chunks</div><div><b>{size(disk.free)}</b>free on nest</div>'
                f'<div><b>{"running" if gc_state["running"] else "idle"}</b>garbage collection</div></div>'
                f'<form class=row method=post action="/-/gc">{csrf_field(who)}<button class=ghost>collect garbage now</button>'
                f'<span class=mute>{e(gc_state["last"])}</span></form>' + body +
                f'<h2>new cache</h2><form class=row method=post action="/-/caches">{csrf_field(who)}'
                f'<input name=name placeholder="name (a-z 0-9 -)" required pattern="[a-z0-9][a-z0-9-]{{0,49}}">'
                f'<select name=visibility><option value=public>public</option><option value=private>private</option></select>'
                f'<button>create</button></form>')
    body += (f'<h2>paths</h2><form><input class=wide name=q value="{e(search)}" placeholder="search store paths" autofocus>'
             f'</form>{path_rows("o.store_path LIKE ?", (f"%{search}%",), who)}')
    return layout("cache", body, who, flash)


def cache_page(who, name, search, flash, token=""):
    e = html.escape
    found = [c for c in visible_caches(who) if c[0] == name]
    if not found:
        return None
    _, keypair, public, count, total, last = found[0]
    key = public_key(keypair)
    conf = f"extra-substituters = {URL}/{name}\nextra-trusted-public-keys = {key}"
    body = (f'<h2>{e(name)} {"" if public else "<span class=pill>private</span>"}</h2>'
            f'<div class="card stats"><div><b>{count}</b>paths</div><div><b>{size(total)}</b>uncompressed</div>'
            f'<div><b>{e(when(last))}</b>last push</div></div>'
            f'<div class=card><div class=mute>nix.conf <button class="ghost small" data-copy=conf>copy</button></div>'
            f'<pre id=conf>{e(conf)}</pre></div>')
    if token:
        body += (f'<div class=card><div class=mute>new token: shown only now '
                 f'<button class="ghost small" data-copy=token>copy</button></div><pre id=token>{e(token)}</pre></div>')
    pins = [(n, p["storePath"]) for n, p in sorted(read_pins().items())
            if query("SELECT 1 FROM object o JOIN cache c ON c.id = o.cache_id WHERE c.name = ? AND o.store_path = ?",
                     (name, p["storePath"]))]
    pin_rows = "".join(
        f'<tr><td>{e(n)}</td><td class=mute title="{e(p)}">{e(p.removeprefix("/nix/store/")[:60])}</td>'
        + (f'<td class=num><form class=inline method=post action="/-/cache/{quote(name)}/unpin">{csrf_field(who)}'
           f'<input type=hidden name=pin value="{e(n)}"><button class="danger small">unpin</button></form></td>' if who else "")
        + "</tr>" for n, p in pins) or f'<tr><td colspan=3 class=mute>no pins</td></tr>'
    body += f'<h2>pins</h2><table><tr><th>name</th><th>store path</th>{"<th></th>" if who else ""}</tr>{pin_rows}</table>'
    if who:
        body += (f'<form class=row method=post action="/-/cache/{quote(name)}/pin">{csrf_field(who)}'
                 f'<input name=pin placeholder="pin name, e.g. tool-x86_64-linux" required>'
                 f'<input name=path placeholder="/nix/store/..." required style="flex:1"><button>set pin</button></form>')
    body += (f'<h2>paths</h2><form><input class=wide name=q value="{e(search)}" placeholder="search this cache"></form>'
             + path_rows("c.name = ? AND o.store_path LIKE ?", (name, f"%{search}%"), who, deletable=True if who else None))
    if who:
        body += (f'<h2>manage</h2>'
                 f'<form class=row method=post action="/-/cache/{quote(name)}/cleanup">{csrf_field(who)}'
                 f'<button class=ghost>delete everything unpinned</button>'
                 f'<span class=mute>keeps pins, what they need, and anything pushed in the last day</span></form>'
                 f'<form class=row method=post action="/-/cache/{quote(name)}/visibility">{csrf_field(who)}'
                 f'<input type=hidden name=public value="{"0" if public else "1"}">'
                 f'<button class=ghost>make {"private" if public else "public"}</button></form>'
                 f'<form class=row method=post action="/-/cache/{quote(name)}/token">{csrf_field(who)}'
                 f'<input name=sub placeholder="who it is for, e.g. github-ci" required>'
                 f'<select name=access><option value=pull>pull</option><option value=push>pull and push</option></select>'
                 f'<select name=validity><option>30d</option><option selected>1y</option><option>5y</option></select>'
                 f'<button>issue token</button></form>'
                 f'<form class=row method=post action="/-/cache/{quote(name)}/destroy">{csrf_field(who)}'
                 f'<input name=confirm placeholder="type {e(name)} to delete the whole cache" required>'
                 f'<button class=danger>delete cache</button></form>')
    return layout(name, body, who, flash)


def login_page(flash=""):
    return layout("sign in", '<h2>sign in</h2><form method=post action="/-/login" class=card style="max-width:360px">'
                  '<p><input class=wide name=user placeholder=user autocomplete=username required autofocus></p>'
                  '<p><input class=wide type=password name=password placeholder=password autocomplete=current-password required></p>'
                  '<button>sign in</button></form>', None, flash)


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body, kind="text/html; charset=utf-8", headers=()):
        body = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Frame-Options", "DENY")
        for header in headers:
            self.send_header(*header)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, to, flash="", headers=()):
        target = to + (("&" if "?" in to else "?") + "msg=" + quote(flash) if flash else "")
        self.reply(303, "", headers=[("Location", target), *headers])

    def who(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        return session(cookie["cache_session"].value if "cache_session" in cookie else "")

    def form(self):
        length = min(int(self.headers.get("Content-Length", "0")), 65536)
        return {k: v[0] for k, v in parse_qs(self.rfile.read(length).decode(errors="replace")).items()}

    def do_PUT(self):
        name = urlparse(self.path).path.removeprefix("/-/pins/")
        if not PIN_NAME.fullmatch(name) or self.path == name:
            return self.reply(404, "not found\n", "text/plain")
        given = self.headers.get("Authorization", "").removeprefix("Bearer ")
        if not PIN_TOKEN or not hmac.compare_digest(given.encode(), PIN_TOKEN.encode()):
            return self.reply(401, "bad pin token\n", "text/plain")
        length = int(self.headers.get("Content-Length", "0"))
        path = self.rfile.read(min(length, 512)).decode(errors="replace").strip()
        if not STORE_PATH.fullmatch(path):
            return self.reply(400, "body must be one store path\n", "text/plain")
        # Only paths the cache holds, so a pin can never point at nothing.
        if not query("SELECT 1 FROM object WHERE store_path = ?", (path,)):
            return self.reply(409, "path is not in the cache; push it first\n", "text/plain")
        set_pin(name, path)
        self.reply(200, f"{name} -> {path}\n", "text/plain")

    def do_GET(self):
        url = urlparse(self.path)
        args = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path == "/-/pins":
            pins = [{"name": n, "lastRevision": {"storePath": p["storePath"]}} for n, p in sorted(read_pins().items())]
            return self.reply(200, json.dumps(pins), "application/json")
        try:
            who = self.who()
            if url.path == "/-/login":
                return self.reply(200, login_page(args.get("msg", "")))
            if url.path in ("/", "/-/"):
                return self.reply(200, overview(who, args.get("q", ""), args.get("msg", "")))
            name = url.path.removeprefix("/-/cache/")
            if url.path.startswith("/-/cache/") and CACHE_NAME.fullmatch(name):
                page = cache_page(who, name, args.get("q", ""), args.get("msg", ""))
                if page:
                    return self.reply(200, page)
            self.reply(404, layout("not found", "<h2>not found</h2>", who))
        except sqlite3.Error as err:
            self.reply(503, f"database not ready: {html.escape(str(err))}", "text/plain")

    def do_POST(self):
        path, form = urlparse(self.path).path, self.form()
        if path == "/-/login":
            user = form.get("user", "")
            if USER_NAME.fullmatch(user) and check_login(user, form.get("password", "")):
                secure = "; Secure" if self.headers.get("X-Forwarded-Proto") == "https" else ""
                cookie = (f"cache_session={new_session(user)}; Path=/; HttpOnly; SameSite=Strict; "
                          f"Max-Age={SESSION_DAYS * 86400}{secure}")
                return self.redirect("/", f"signed in as {user}", [("Set-Cookie", cookie)])
            time.sleep(1)
            return self.redirect("/-/login", "wrong user or password")
        who = self.who()
        if not who or not hmac.compare_digest(form.get("csrf", ""), who["csrf"]):
            return self.redirect("/-/login", "sign in first")
        if path == "/-/logout":
            with ui_db() as db:
                db.execute("DELETE FROM sessions WHERE token = ?", (who["token"],))
            return self.redirect("/", "signed out", [("Set-Cookie", "cache_session=; Path=/; Max-Age=0")])
        try:
            self.manage(path, form, who)
        except (urllib.error.URLError, subprocess.CalledProcessError, sqlite3.Error, OSError, ValueError) as err:
            self.redirect(self.headers.get("Referer", "/").replace(URL, "") or "/", f"failed: {err}")

    def manage(self, path, form, who):
        if path == "/-/gc":
            start_gc()
            return self.redirect("/", "garbage collection started")
        if path == "/-/caches":
            name = form.get("name", "")
            if not CACHE_NAME.fullmatch(name):
                return self.redirect("/", "cache names are a-z, 0-9 and -, up to 50")
            attic("POST", f"/_api/v1/cache-config/{name}", {
                "keypair": "Generate", "is_public": form.get("visibility") == "public", "store_dir": "/nix/store",
                "priority": 41, "upstream_cache_key_names": ["cache.nixos.org-1"]})
            return self.redirect(f"/-/cache/{name}", f"created {name}")
        _, _, rest = path.partition("/-/cache/")
        name, _, action = rest.partition("/")
        if not CACHE_NAME.fullmatch(name) or not query("SELECT 1 FROM cache WHERE name = ? AND deleted_at IS NULL", (name,)):
            return self.redirect("/", "no such cache")
        back = f"/-/cache/{name}"
        if action == "delete-path":
            target = form.get("path", "")
            if not STORE_PATH.fullmatch(target):
                return self.redirect(back, "not a store path")
            keep = pinned_paths()
            if target in keep:
                return self.redirect(back, "that path is pinned; unpin it first")
            if any(os.path.basename(target) in json.loads(refs or "[]")
                   or target in json.loads(refs or "[]")
                   for path_, refs in query('SELECT store_path, "references" FROM object') if path_ in keep):
                return self.redirect(back, "a pinned path depends on it; unpin that first")
            deleted = write("DELETE FROM object WHERE store_path = ? AND cache_id = (SELECT id FROM cache WHERE name = ?)",
                            (target, name))
            start_gc()
            return self.redirect(back, f"deleted {deleted} path(s); garbage collection started")
        if action == "cleanup":
            return self.redirect(back, f"deleted {cleanup(name)} unpinned path(s); garbage collection started")
        if action == "visibility":
            attic("PATCH", f"/_api/v1/cache-config/{name}", {"is_public": form.get("public") == "1"})
            return self.redirect(back, "visibility changed")
        if action == "pin":
            pin, target = form.get("pin", ""), form.get("path", "").strip()
            if not PIN_NAME.fullmatch(pin) or not STORE_PATH.fullmatch(target):
                return self.redirect(back, "bad pin name or store path")
            if not query("SELECT 1 FROM object o JOIN cache c ON c.id = o.cache_id WHERE c.name = ? AND o.store_path = ?",
                         (name, target)):
                return self.redirect(back, "that path is not in this cache")
            set_pin(pin, target)
            return self.redirect(back, f"pinned {pin}")
        if action == "unpin":
            save_pins(lambda p: p.pop(form.get("pin", ""), None))
            return self.redirect(back, f"unpinned {form.get('pin', '')}")
        if action == "token":
            sub = form.get("sub", "")
            if not USER_NAME.fullmatch(sub) or form.get("validity") not in ("30d", "1y", "5y"):
                return self.redirect(back, "token names are a-z, 0-9, _ and -")
            perms = [f"--pull={name}"] + ([f"--push={name}"] if form.get("access") == "push" else [])
            token = make_token(sub, form["validity"], perms)
            return self.reply(200, cache_page(who, name, "", f"token for {sub}", token),
                              headers=[("Cache-Control", "no-store")])
        if action == "destroy":
            if form.get("confirm") != name:
                return self.redirect(back, "type the cache name exactly to delete it")
            keep = pinned_paths()
            held = query("SELECT o.store_path FROM object o JOIN cache c ON c.id = o.cache_id WHERE c.name = ?", (name,))
            if any(path_ in keep for (path_,) in held):
                return self.redirect(back, "this cache still holds pinned paths; unpin them first")
            attic("DELETE", f"/_api/v1/cache-config/{name}")
            start_gc()
            return self.redirect("/", f"deleted cache {name}")
        self.redirect(back, "unknown action")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    if sys.argv[1:2] == ["user"]:
        users_cli(sys.argv[2:])
    else:
        host, port = env("CACHE_LISTEN", "127.0.0.1:8082").rsplit(":", 1)
        ThreadingHTTPServer((host, int(port)), Handler).serve_forever()
