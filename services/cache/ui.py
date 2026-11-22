"""Cache page over Attic: people sign in with id.bresilla.com; its cache admins manage caches.

GET /-/pins answers like app.cachix.org/api/v1/cache/<name>/pin; CI sets a pin
with PUT /-/pins/<name> (body: the store path) and the pin token.
"""

import site_ui
import base64
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
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

env = os.environ.get
DB = env("CACHE_DB", "")
UI_DB = env("CACHE_UI_DB", "")
URL = env("CACHE_URL", "").rstrip("/")
PINS = env("CACHE_PINS_FILE", "")
PIN_TOKEN = env("CACHE_PIN_TOKEN", "")
# Signs the CSRF field of proxy-signed-in visitors; new on every start.
PROXY_CSRF_KEY = secrets.token_bytes(32)
API = env("CACHE_API", "http://127.0.0.1:8081")
ATTICADM = shlex.split(env("CACHE_ATTICADM", ""))
GC = shlex.split(env("CACHE_GC", ""))
# Pins the old GitHub CI still commits, mirrored here until it is retired:
# (file, groups in it, whether names get the group as suffix). A pin set through
# the API is never overwritten by these.
LEGACY_PINS = (
    ("https://raw.githubusercontent.com/bresilla/devices/main/pins.json", ("aarch64-linux", "kernels"), False),
)
# The only caches cleanup touches, as in attic-gc.
PRUNED = ("bresilla", "packages")
PIN_NAME = re.compile(r"[A-Za-z0-9._+-]{1,100}")
CACHE_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,49}")
USER_NAME = re.compile(r"[a-z0-9_-]{1,32}")
STORE_PATH = re.compile(r"/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+?=-]+")
SIGN_OUT = site_ui.SIGN_OUT
ADMINS_ONLY = "only cache admins on id.bresilla.com may do that"
# Who is looking at the page being made, admin or not; nobody when signed out.
VIEW = threading.local()
pins_lock = threading.Lock()
gc_state = {"running": False, "last": "not run since the page started"}

STYLE = site_ui.STYLE + """
/* Forms inside a reveal panel or section: fields, then their button. */
form.stack { display: grid; gap: var(--s3); max-width: 720px; margin: 0; }
td .path { display: flex; flex-direction: column; min-width: 0; }
td .path small { color: var(--mute); font-family: var(--site-code-font); font-size: var(--site-font-tiny); }
section.set details.reveal { margin-bottom: var(--s3); }
section.set details.reveal:last-child { margin-bottom: 0; }
.tile dl:has(.big) { align-items: baseline; }
.tile .foot code { font-size: var(--site-font-tiny); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
/* Narrow: wide tables scroll inside their section instead of the page. */
@media (max-width: 720px) { section.set > div:has(> table) { overflow-x: auto; } td .path { min-width: 10em; } }
"""

SCRIPT = site_ui.SCRIPT + """
document.addEventListener("click", (event) => {
  const id = event.target.dataset?.copy;
  if (!id) return;
  const text = document.getElementById(id).textContent;
  const button = event.target;
  navigator.clipboard?.writeText(text).then(() => {
    button.classList.add("done");
    setTimeout(() => button.classList.remove("done"), 1200);
  }, () => getSelection().selectAllChildren(document.getElementById(id)));
});
"""

ICONS = site_ui.ICONS


logo = site_ui.logo


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


# The page's own records, separate from Attic's database: issued Attic tokens,
# never the tokens themselves. The accounts it once kept are gone with id.bresilla.com.

def ui_db():
    db = sqlite3.connect(UI_DB, timeout=10)
    db.execute("CREATE TABLE IF NOT EXISTS tokens (cache TEXT, sub TEXT, access TEXT, validity TEXT, created TEXT, by TEXT)")
    db.execute("DROP TABLE IF EXISTS users")
    db.execute("DROP TABLE IF EXISTS sessions")
    return db


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


# Pins: all in this cache's own file, each with where it came from: "api" (CI or
# this page) or "github" (mirrored from LEGACY_PINS until the old CI is retired).

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


def set_pin(name, path, source="api"):
    save_pins(lambda p: p.update({name: {"storePath": path, "source": source,
                                         "updated": datetime.now(timezone.utc).isoformat()}}))


def mirror_legacy_pins():
    """Copies the GitHub pins files in, never over a pin the API has set."""
    found = {}
    for url, groups, suffix in LEGACY_PINS:
        with urllib.request.urlopen(url, timeout=15) as response:
            for group, entries in json.load(response).items():
                if group in groups:
                    found.update({(f"{n}-{group}" if suffix else n): p for n, p in entries.items()})

    def change(pins):
        now = datetime.now(timezone.utc).isoformat()
        for name, path in found.items():
            old = pins.get(name)
            if old is None or (old.get("source") == "github" and old["storePath"] != path):
                pins[name] = {"storePath": path, "source": "github", "updated": now}
    save_pins(change)


def mirror_loop():
    while True:
        try:
            mirror_legacy_pins()
        except (OSError, ValueError) as err:
            print(f"pins mirror: {err}", flush=True)
        time.sleep(300)


def cache_pins(cache):
    # Every pin that names a path in this cache, as (name, details), sorted by name.
    found = []
    for n, p in sorted(read_pins().items()):
        pushed = query("SELECT o.created_at FROM object o JOIN cache c ON c.id = o.cache_id "
                       "WHERE c.name = ? AND o.store_path = ?", (cache, p["storePath"]))
        if pushed:
            found.append((n, {"updated": pushed[0][0], **p}))
    return found


def pinned_paths(cache):
    # The pins that protect a cache; a pin only keeps what its own cache holds.
    return {p["storePath"] for p in read_pins().values()}


def systems():
    # Attic records no system; pin names say it, and dependencies take it from
    # the pinned package that references them.
    found = {}
    for name, p in read_pins().items():
        for system in ("x86_64-linux", "aarch64-linux", "riscv64-linux"):
            if name.endswith(f"-{system}"):
                found[os.path.basename(p["storePath"])] = system
    for path, refs in query('SELECT store_path, "references" FROM object'):
        system = found.get(os.path.basename(path))
        for ref in json.loads(refs or "[]") if system else []:
            found.setdefault(os.path.basename(ref), system)
    return found


def on_nixos_org(path):
    # Whether cache.nixos.org has it; when unsure, it counts as not there and stays.
    name = os.path.basename(path).split("-")[0]
    try:
        urllib.request.urlopen(urllib.request.Request(f"https://cache.nixos.org/{name}.narinfo", method="HEAD"), timeout=20)
        return True
    except (urllib.error.URLError, TimeoutError):
        return False


def cleanup(cache):
    # Unpinned, not needed by anything pinned, and older than a day (CI pins after pushing);
    # and, pinned closure or not, whatever cache.nixos.org has, which machines get from there.
    # Only these caches are pruned: /kernels and /firmwares hold unpinned paths on purpose.
    if cache not in PRUNED:
        return 0
    keep = pinned_paths(cache)
    if not keep:
        return 0
    rows = query('SELECT o.id, o.store_path, o."references", o.created_at FROM object o JOIN cache c ON c.id = o.cache_id '
                 "WHERE c.name = ?", (cache,))
    # The whole closure of pinned paths within this cache stays.
    refs = {os.path.basename(path): json.loads(r or "[]") for _, path, r, _ in rows}
    needed, todo = set(), [os.path.basename(p) for p in keep]
    while todo:
        name = todo.pop()
        if name not in needed:
            needed.add(name)
            todo.extend(os.path.basename(r) for r in refs.get(name, []))
    cutoff = datetime.now(timezone.utc).timestamp() - 86400
    unpinned = [path for _, path, _, _ in rows if path not in keep]
    with ThreadPoolExecutor(16) as pool:
        upstream = {path for path, there in zip(unpinned, pool.map(on_nixos_org, unpinned)) if there}
    doomed = [i for i, path, _, created in rows
              if path in upstream or (path not in keep and os.path.basename(path) not in needed
                                      and datetime.fromisoformat(created[:19]).replace(tzinfo=timezone.utc).timestamp() < cutoff)]
    for object_id in doomed:
        write("DELETE FROM object WHERE id = ?", (object_id,))
    return len(doomed)


# Pages: caches as tiles, a new-cache page, and per cache a band with the tabs
# overview, push, store paths, pins and (signed in) settings.

PAGE_SIZE = 50
e = html.escape
pill = site_ui.pill


def layout(title, body, who, flash="", nav="caches", band=""):
    # The band stays first in main so it meets the header; the notice goes under it.
    links = [("caches", "/", "Caches")] + ([("settings", "/-/settings", "Settings")] if who else [])
    note = f'<div class=flash>{e(flash)}</div>' if flash else ""
    return site_ui.page(site="cache", title=title, body=band + note + body, links=links, active=nav,
                        name=getattr(VIEW, "name", None), here=getattr(VIEW, "path", "/"),
                        style=STYLE, script=SCRIPT)


def csrf_field(who):
    return f'<input type=hidden name=csrf value="{e(who["csrf"])}">'


def post_form(action, who, fields, button, kind="", extra=""):
    # A form that posts with the CSRF field: its fields, then one button.
    return (f'<form class=stack method=post action="{e(action)}">{csrf_field(who)}{extra}{fields}'
            f'<div class=actions><button class="{kind}">{e(button)}</button></div></form>')


def visibility_pill(public):
    return pill("ok", "public") if public else pill("none", "private")


def token_form(action, who, example):
    fields = (f'<div class=fields><label>who it is for</label><input name=sub placeholder="e.g. {e(example)}" required '
              f'pattern="[a-z0-9_-]{{1,32}}">'
              f'<label>access</label><select name=access><option value=pull>pull</option>'
              f'<option value=push>pull and push</option></select>'
              f'<label>valid for</label><select name=validity><option>30d</option><option selected>1y</option>'
              f'<option>5y</option></select></div>')
    return post_form(action, who, fields, "generate")


def issued_table(issued):
    rows = [(e(s), pill("ok" if a == "pull and push" else "none", a), e(v), f'<span class=mute>{e(when(c))}</span>',
             f'<span class=mute>{e(b)}</span>') for s, a, v, c, b in issued]
    if not rows:
        return '<p class=mute>None issued from this page yet.</p>'
    return site_ui.table(["name", "access", "valid for", "issued", "by"], rows)


def shown_token(token):
    return ('<div class=flash>Copy it now: it is not stored and will not be shown again.</div>'
            + copy_block("token", token)) if token else ""


def visible_caches(who):
    return query(
        "SELECT c.name, c.keypair, c.is_public, COUNT(o.id), COALESCE(SUM(n.nar_size), 0), MAX(o.created_at) "
        "FROM cache c LEFT JOIN object o ON o.cache_id = c.id LEFT JOIN nar n ON n.id = o.nar_id "
        f"WHERE c.deleted_at IS NULL {'' if who else 'AND c.is_public'} GROUP BY c.id ORDER BY c.name")


def find_cache(who, name):
    found = [c for c in visible_caches(who) if c[0] == name]
    return found[0] if found else None


def cache_band(who, cache, current):
    # The cache's name, what it holds, and its tabs with the paths and pins counted.
    name, _, public, count, total, last = cache
    pins = len(cache_pins(name))
    tabs = [("overview", "", "Overview", "overview", None), ("push", "/push", "Push", "push", None),
            ("paths", "/paths", "Paths", "paths", count), ("pins", "/pins", "Pins", "pin", pins)]
    if who:
        tabs.append(("settings", "/settings", "Settings", "settings", None))
    items = [(f"/-/cache/{quote(name)}{suffix}", label, ico, n, None, key == current) for key, suffix, label, ico, n in tabs]
    summary = visibility_pill(public) + f'<span>{size(total)} · {count} paths · {pins} pins · last push {e(when(last))}</span>'
    return site_ui.band(name, "public" if public else "private", crumbs=[("/", "caches")], summary=summary, items=items)


def key_capsule(keypair):
    return (f'<div class=key><span class=mute>Public key</span><code id=publickey>{e(public_key(keypair))}</code>'
            f'<button class=iconbtn title=copy data-copy=publickey>{ICONS["copy"]}</button></div>')


def copy_block(block_id, text):
    return (f'<div class=cmd><button class=iconbtn title=copy data-copy={block_id}>{ICONS["copy"]}</button>'
            f'<pre id={block_id}>{e(text)}</pre></div>')


def step(number, title):
    return f'<div class=step><span>STEP {number}</span>{e(title)}</div>'


def new_cache_form(who, focus=False):
    fields = (f'<div class=fields><label>name</label><input name=name required pattern="[a-z0-9][a-z0-9-]{{0,49}}" '
              f'placeholder="my-cache"{" autofocus" if focus else ""}></div>'
              f'<p class=mute>Part of the substituter URL and of every machine\'s nix.conf, so choose it carefully: '
              f'lowercase letters, digits and dashes.</p>'
              f'<div class=options>'
              f'<label class=choice><input type=radio name=visibility value=public checked> <b>public</b>'
              f'<span>anyone can download from it; pushing needs a token</span></label>'
              f'<label class=choice><input type=radio name=visibility value=private> <b>private</b>'
              f'<span>downloading needs a token too; hidden from this page when signed out</span></label></div>'
              f'<p class=mute>A signing key is generated for the cache; its public half is shown on the cache\'s overview.</p>')
    return post_form("/-/caches", who, fields, "create cache")


def dashboard(who, flash):
    caches = visible_caches(who)
    pins = {name: len(cache_pins(name)) for name, *_ in caches}
    tiles = "".join(
        site_ui.tile(name, [("paths", str(count)), ("size", size(total)), ("pins", str(pins[name])),
                            ("newest push", e(when(last)))],
                     href=f"/-/cache/{quote(name)}", note=visibility_pill(public),
                     foot=f'<code>{e(URL)}/{e(name)}</code>')
        for name, _, public, count, total, last in caches)
    listing = f'<div class=grid>{tiles}</div>' if tiles else '<div class="card empty">no caches yet</div>'
    summary = (f'<span>{len(caches)} caches · {size(sum(c[4] for c in caches))} · {sum(c[3] for c in caches)} paths · '
               f'{sum(pins.values())} pins</span>')
    new = site_ui.reveal("New cache", new_cache_form(who)) if who else ""
    band = site_ui.band("Caches", "database", summary=summary)
    return layout("caches", new + listing, who, flash, "caches", band)


def general_settings(who, flash, token=""):
    with ui_db() as db:
        issued = db.execute("SELECT sub, access, validity, created, by FROM tokens WHERE cache = '*' ORDER BY created DESC"
                            ).fetchall()
    stored = query("SELECT COALESCE(SUM(file_size), 0) FROM chunk WHERE state = 'V'")[0][0]
    disk = shutil.disk_usage(os.path.dirname(DB))
    prune = ", ".join(f"/{name}" for name in PRUNED)
    running = gc_state["running"]
    # Storage at a glance, then cleanup, tokens for every cache, the pin token and accounts.
    storage = ('<div class=grid>'
               + site_ui.tile("Stored", [("all caches", f'<span class=big>{size(stored)}</span>')])
               + site_ui.tile("Database disk", [("free", f'<span class=big>{size(disk.free)}</span>')])
               + site_ui.tile("Garbage collection", [("now", pill("warn" if running else "ok", "running" if running else "idle")),
                                                     ("last", e(gc_state["last"]))])
               + '</div>')
    clean = site_ui.reveal("1. Delete unpinned builds", post_form(
        "/-/clean", who, f'<p>Deletes unpinned builds older than a day from {e(prune)} now, as the nightly run does. '
                         f'Their data stays on disk until it is freed.</p>', "delete unpinned builds", "danger"),
        ico="trash", kind="danger")
    free = (f'<form class=inline method=post action="/-/gc">{csrf_field(who)}<input type=hidden name=back value="/-/settings">'
            f'<button class=ghost>2. Free deleted data</button></form>')
    gc = (f'<p class=mute>Every night, unpinned builds older than a day are deleted from {e(prune)}, and their data is '
          f'freed afterwards. Other caches are never pruned. By hand: first delete, then free.</p>'
          f'{clean}<div class=actions>{free}</div>')
    tokens = (shown_token(token) +
              '<p class=mute>One token for every cache, including ones made later; a cache\'s own settings make tokens '
              'for that cache alone, which is safer when one cache is enough.</p>'
              + site_ui.reveal("New token", token_form("/-/token", who, "ci"), ico="key")
              + issued_table(issued))
    pin_token = ('<p class=mute>What CI sends to set pins (PUT /-/pins/&lt;name&gt;); build.bresilla.com needs it in its '
                 'Settings.</p>' + (site_ui.reveal("Show the pin token", copy_block("pintoken", PIN_TOKEN), ico="key",
                                                   kind="ghost") if PIN_TOKEN else '<p class=mute>not set on this server</p>'))
    accounts = ('<p class=mute>People sign in with <a href="https://id.bresilla.com">id.bresilla.com</a>; the cache_users '
                'group may sign in, cache_admins may change things.</p>')
    body = (storage + site_ui.section("Cleanup", gc, "warn" if running else None)
            + site_ui.section("Auth tokens, all caches", tokens, note=f"{len(issued)} issued")
            + site_ui.section("Pin token", pin_token) + site_ui.section("Accounts", accounts))
    summary = (f'<span>{size(stored)} stored · {size(disk.free)} free</span>'
               + pill("warn" if running else "ok", "cleanup running" if running else "cleanup idle"))
    band = site_ui.band("Settings", "settings", crumbs=[("/", "caches")], summary=summary)
    return layout("settings", body, who, flash, "settings", band)


def new_cache_page(who, flash):
    band = site_ui.band("New cache", "plus", crumbs=[("/", "caches")])
    return layout("new cache", f'<section class=set><h3>New cache</h3><div>{new_cache_form(who, True)}</div></section>',
                  who, flash, band=band)


def overview_page(who, cache, flash):
    name, keypair, public = cache[:3]
    key = public_key(keypair)
    conf = f"extra-substituters = {URL}/{name}\nextra-trusted-public-keys = {key}"
    flake = (f'nixConfig = {{\n  extra-substituters = [ "{URL}/{name}" ];\n'
             f'  extra-trusted-public-keys = [ "{key}" ];\n}};')
    body = (key_capsule(keypair) + step(1, "Add the cache to Nix") +
            f'<p>In <code>/etc/nix/nix.conf</code>, or <code>nix.settings</code> on NixOS'
            f'{"" if public else "; this cache is private, so a pull token goes in netrc-file"}:</p>'
            + copy_block("conf", conf) + step(2, "Or carry it in a flake") +
            '<p>Nix asks before using a cache named by a flake:</p>' + copy_block("flake", flake))
    return layout(name, body, who, flash, band=cache_band(who, cache, "overview"))


def push_page(who, cache, flash):
    name = cache[0]
    token = "Generate one in this cache's Settings." if who else "Ask the owner of this cache for one."
    body = (step(1, "Get a push token") + f'<p>{token}</p>' +
            step(2, "Log in") + '<p>With the attic client:</p>' + copy_block("login", f"$ attic login home {URL} <token>") +
            step(3, "Push") + copy_block("push", f"$ attic push home:{name} ./result") +
            f'<p class=mute>Uploads through {e(URL)} stop at 100 MB; larger paths need a login on the server\'s '
            f'private address instead.</p>')
    return layout(f"{name} · push", body, who, flash, band=cache_band(who, cache, "push"))


def pin_closure(name):
    # The pinned paths, and the names of everything they need within this cache.
    keep = pinned_paths(name)
    refs = {os.path.basename(path): json.loads(r or "[]") for path, r in query(
        'SELECT o.store_path, o."references" FROM object o JOIN cache c ON c.id = o.cache_id WHERE c.name = ?', (name,))}
    needed, todo = set(), [os.path.basename(p) for p in keep]
    while todo:
        base = todo.pop()
        if base not in needed:
            needed.add(base)
            todo.extend(os.path.basename(r) for r in refs.get(base, []))
    return keep, needed


def path_state(name, path, created, keep, needed):
    # What cleanup does with a path: kept as a pin or for one, or deleted once older than a day.
    if path in keep:
        return pill("ok", "pinned")
    if os.path.basename(path) in needed:
        return f'<span title="a pinned path needs it">{pill("ok", "needed")}</span>'
    if name not in PRUNED:
        return f'<span title="this cache is never pruned">{pill("none", "kept")}</span>'
    age = datetime.now(timezone.utc).timestamp() - datetime.fromisoformat(created[:19]).replace(tzinfo=timezone.utc).timestamp()
    if age > 86400:
        return f'<span title="the next cleanup deletes it">{pill("warn", "unpinned")}</span>'
    return f'<span title="less than a day old; spared until CI pins it">{pill("none", "new")}</span>'


def path_cell(path):
    digest, _, pname = path.removeprefix("/nix/store/").partition("-")
    return f'<span class=path title="{e(path)}">{e(pname)}<small>{e(digest[:12])}</small></span>'


def paths_page(who, cache, search, page, flash):
    name = cache[0]
    arch = systems()
    keep, needed = pin_closure(name)
    where = "c.name = ? AND o.store_path LIKE ?"
    args = (name, f"%{search}%")
    total = query(f"SELECT COUNT(*) FROM object o JOIN cache c ON c.id = o.cache_id WHERE {where}", args)[0][0]
    rows = query(
        "SELECT o.store_path, n.nar_size, o.created_at FROM object o JOIN cache c ON c.id = o.cache_id "
        f"JOIN nar n ON n.id = o.nar_id WHERE {where} ORDER BY o.created_at DESC LIMIT ? OFFSET ?",
        args + (PAGE_SIZE, page * PAGE_SIZE))
    out = []
    for path, nar, created in rows:
        row = [path_cell(path), path_state(name, path, created, keep, needed),
               f'<span class=mute>{e(arch.get(os.path.basename(path), ""))}</span>', size(nar),
               f'<span class=mute>{e(when(created))}</span>']
        # A pinned path cannot be deleted; unpinning it comes first.
        if who and path in keep:
            row.append('')
        elif who:
            row.append(f'<form class=inline method=post action="/-/cache/{quote(name)}/delete-path">'
                       f'{csrf_field(who)}<input type=hidden name=path value="{e(path)}">'
                       f'<button class="danger small">delete</button></form>')
        out.append(row)
    head = ["path", "state", "system", "size", "pushed"] + ([""] if who else [])
    table = site_ui.table(head, out, numeric=(3, 5)) if out else '<div class=empty>nothing found</div>'
    base = f"/-/cache/{quote(name)}/paths?q={quote(search)}"
    pages = max(1, -(-total // PAGE_SIZE))
    prev = f'<a href="{base}&page={page - 1}">← newer</a>' if page > 0 else "<span></span>"
    nxt = f'<a href="{base}&page={page + 1}">older →</a>' if page + 1 < pages else "<span></span>"
    body = (f'<form class=row><input class=wide name=q value="{e(search)}" placeholder="search store paths" autofocus></form>'
            + site_ui.section("Store paths", table, note=f"{total} found · page {page + 1} of {pages}")
            + f'<div class=pager>{prev}{nxt}</div>')
    return layout(f"{name} · paths", body, who, flash, band=cache_band(who, cache, "paths"))


def pins_page(who, cache, flash):
    name = cache[0]
    rows = []
    for n, p in cache_pins(name):
        row = [e(n), path_cell(p["storePath"]),
               pill("none", "GitHub mirror") if p.get("source") == "github" else pill("ok", "CI"),
               f'<span class=mute>{e(when(p.get("updated")))}</span>']
        if who:
            row.append(f'<form class=inline method=post action="/-/cache/{quote(name)}/unpin">{csrf_field(who)}'
                       f'<input type=hidden name=pin value="{e(n)}"><button class="danger small">unpin</button></form>')
        rows.append(row)
    table = site_ui.table(["name", "store path", "from", "updated"] + ([""] if who else []), rows, numeric=(4,)) \
        if rows else '<div class=empty>no pins</div>'
    kept = ('Nothing in this cache is ever pruned.' if name not in PRUNED
            else 'Pinned paths, and what they depend on, are kept by cleanup; everything else older than a day goes.')
    body = (f'<p class=mute>A pin is a stable name for the newest build of something. {kept} CI sets them through '
            f'the pin API; ones marked GitHub are still mirrored from an old pins.json until that CI is retired. '
            f'Machines read them at <code>{e(URL)}/-/pins</code>.</p>')
    if who:
        fields = ('<div class=fields><label>name</label><input name=pin placeholder="e.g. eva-x86_64-linux" required>'
                  '<label>store path</label><input name=path placeholder="/nix/store/..." required></div>')
        body += site_ui.reveal("Set a pin", post_form(f"/-/cache/{quote(name)}/pin", who, fields, "pin"), ico="pin")
    body += site_ui.section("Pins", table, note=f"{len(rows)} in this cache")
    return layout(f"{name} · pins", body, who, flash, band=cache_band(who, cache, "pins"))


def settings_page(who, cache, flash, token=""):
    name, _, public = cache[:3]
    act = f"/-/cache/{quote(name)}"
    with ui_db() as db:
        issued = db.execute("SELECT sub, access, validity, created, by FROM tokens WHERE cache = ? ORDER BY created DESC",
                            (name,)).fetchall()
    tokens = (shown_token(token) +
              '<p class=mute>Tokens for CI and other machines. Attic tokens cannot be revoked one by one, so give each a '
              'clear name and the shortest life that works.</p>'
              + site_ui.reveal("New token", token_form(f"{act}/token", who, "github-ci"), ico="key") + issued_table(issued))
    cleanup_section = (
        '<p class=mute>Unpinned builds older than a day are deleted here every night, and their data freed afterwards.</p>'
        + site_ui.reveal("Delete unpinned builds now", post_form(
            f"{act}/cleanup", who, '<p>Deletes every unpinned build older than a day, and anything cache.nixos.org has, '
                                   'from this cache now. Free their data in Settings afterwards.</p>',
            "delete unpinned builds", "danger"), ico="trash", kind="danger")
    ) if name in PRUNED else '<p class=mute>This cache is never pruned: paths stay until deleted by hand.</p>'
    other = "private" if public else "public"
    visibility = (f'<p>This cache is {visibility_pill(public)} '
                  f'{"anyone can download from it." if public else "downloading needs a pull token."}</p>'
                  + site_ui.reveal(f"Make it {other}", post_form(
                      f"{act}/visibility", who,
                      f'<p>{"Downloading will need a pull token; machines without one lose the cache." if public else "Anyone will be able to download everything in it."}</p>',
                      f"make it {other}", "ghost", f'<input type=hidden name=public value="{"0" if public else "1"}">'),
                      ico=other, kind="ghost"))
    destroy = (f'<p>Deleting <b>{e(name)}</b> removes every store path in it and its signing key; machines using it lose '
               f'the cache. A cache that still holds pinned paths cannot be deleted.</p>'
               + site_ui.reveal("Delete this cache", post_form(
                   f"{act}/destroy", who, f'<div class=fields><label>confirm</label>'
                                          f'<input name=confirm placeholder="type {e(name)} to confirm" required></div>',
                   "delete this cache", "danger"), ico="trash", kind="danger"))
    body = (site_ui.section("Auth tokens", tokens, note=f"{len(issued)} issued") + site_ui.section("Cleanup", cleanup_section)
            + site_ui.section("Visibility", visibility)
            + f'<section class="set danger"><h3>Danger zone</h3><div>{destroy}</div></section>')
    return layout(f"{name} · settings", body, who, flash, band=cache_band(who, cache, "settings"))


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
        # Signed in through id.bresilla.com: the login proxy in front passes the name
        # and the cache_role claim; only admins may change things. Machine paths reach
        # this page without the proxy, and Caddy strips these headers on them.
        name = self.headers.get("X-Forwarded-Preferred-Username") or self.headers.get("X-Forwarded-User")
        VIEW.name, VIEW.path = name or None, self.path
        if not name or "admin" not in self.headers.get("X-Forwarded-Groups", "").split(","):
            return None
        return {"user": name, "csrf": hmac.new(PROXY_CSRF_KEY, name.encode(), "sha256").hexdigest()}

    def need_admin(self):
        # Signed out: to id.bresilla.com and back here. Signed in, not an admin: say so.
        if not getattr(VIEW, "name", None):
            return self.redirect(f"/oauth2/start?rd={quote(self.path)}")
        return self.redirect("/", ADMINS_ONLY)

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
        flash = args.get("msg", "")
        if url.path == "/-/pins":
            # Cachix's shape, plus the caches each pinned path is in, which tells
            # machines a kernel pin from a firmware or package one.
            pins = read_pins()
            held = {}
            paths = sorted({p["storePath"] for p in pins.values()})
            for cache, path in query("SELECT c.name, o.store_path FROM object o JOIN cache c ON c.id = o.cache_id "
                                     f"WHERE c.deleted_at IS NULL AND o.store_path IN ({','.join('?' * len(paths))})",
                                     tuple(paths)) if paths else []:
                held.setdefault(path, []).append(cache)
            body = [{"name": n, "lastRevision": {"storePath": p["storePath"]},
                     "caches": sorted(held.get(p["storePath"], []))} for n, p in sorted(pins.items())]
            return self.reply(200, json.dumps(body), "application/json")
        try:
            who = self.who()
            if url.path in ("/", "/-/"):
                return self.reply(200, dashboard(who, flash))
            if url.path == "/-/new":
                return self.reply(200, new_cache_page(who, flash)) if who else self.need_admin()
            if url.path == "/-/settings":
                return self.reply(200, general_settings(who, flash)) if who else self.need_admin()
            name, _, tab = url.path.removeprefix("/-/cache/").partition("/")
            cache = find_cache(who, name) if url.path.startswith("/-/cache/") and CACHE_NAME.fullmatch(name) else None
            if cache and tab == "":
                return self.reply(200, overview_page(who, cache, flash))
            if cache and tab == "push":
                return self.reply(200, push_page(who, cache, flash))
            if cache and tab == "paths":
                page = int(args.get("page", "0")) if args.get("page", "0").isdigit() else 0
                return self.reply(200, paths_page(who, cache, args.get("q", ""), page, flash))
            if cache and tab == "pins":
                return self.reply(200, pins_page(who, cache, flash))
            if cache and tab == "settings":
                return self.reply(200, settings_page(who, cache, flash)) if who else self.need_admin()
            self.reply(404, layout("not found", '<div class="card empty">not found</div>', who))
        except sqlite3.Error as err:
            self.reply(503, f"database not ready: {html.escape(str(err))}", "text/plain")

    def do_POST(self):
        path, form = urlparse(self.path).path, self.form()
        who = self.who()
        if not who or not hmac.compare_digest(form.get("csrf", ""), who["csrf"]):
            return self.redirect("/", ADMINS_ONLY)
        try:
            self.manage(path, form, who)
        except (urllib.error.URLError, subprocess.CalledProcessError, sqlite3.Error, OSError, ValueError) as err:
            back = form.get("back") or (self.headers.get("Referer", "/").replace(URL, "") or "/")
            self.redirect(back.split("?")[0], f"failed: {err}")

    def manage(self, path, form, who):
        if path == "/-/clean":
            deleted = sum(cleanup(name) for name in PRUNED)
            return self.redirect("/-/settings", f"deleted {deleted} unpinned build(s); free their data next")
        if path == "/-/token":
            sub, access, validity = form.get("sub", ""), form.get("access"), form.get("validity")
            if not USER_NAME.fullmatch(sub) or validity not in ("30d", "1y", "5y") or access not in ("pull", "push"):
                return self.redirect("/-/settings", "token names are a-z, 0-9, _ and -")
            token = make_token(sub, validity, ["--pull=*"] + (["--push=*"] if access == "push" else []))
            with ui_db() as db:
                db.execute("INSERT INTO tokens VALUES (?, ?, ?, ?, ?, ?)",
                           ("*", sub, "pull and push" if access == "push" else "pull", validity,
                            datetime.now(timezone.utc).isoformat(), who["user"]))
            return self.reply(200, general_settings(who, f"token for {sub}, all caches", token),
                              headers=[("Cache-Control", "no-store")])
        if path == "/-/gc":
            start_gc()
            back = form.get("back", "/")
            return self.redirect(back if back.startswith("/-/") else "/", "freeing deleted data started")
        if path == "/-/caches":
            name = form.get("name", "")
            if not CACHE_NAME.fullmatch(name):
                return self.redirect("/-/new", "cache names are a-z, 0-9 and -, up to 50")
            if query("SELECT 1 FROM cache WHERE name = ?", (name,)):
                return self.redirect("/-/new", f"{name} already exists")
            attic("POST", f"/_api/v1/cache-config/{name}", {
                "keypair": "Generate", "is_public": form.get("visibility") == "public", "store_dir": "/nix/store",
                "priority": 41, "upstream_cache_key_names": ["cache.nixos.org-1"]})
            return self.redirect(f"/-/cache/{name}", f"created {name}")
        _, _, rest = path.partition("/-/cache/")
        name, _, action = rest.partition("/")
        if not CACHE_NAME.fullmatch(name) or not query("SELECT 1 FROM cache WHERE name = ? AND deleted_at IS NULL", (name,)):
            return self.redirect("/", "no such cache")
        base = f"/-/cache/{name}"
        if action == "delete-path":
            back = f"{base}/paths"
            target = form.get("path", "")
            if not STORE_PATH.fullmatch(target):
                return self.redirect(back, "not a store path")
            keep = pinned_paths(name)
            if target in keep:
                return self.redirect(back, "that path is pinned; unpin it first")
            if any(os.path.basename(target) in json.loads(refs or "[]")
                   or target in json.loads(refs or "[]")
                   for path_, refs in query('SELECT store_path, "references" FROM object') if path_ in keep):
                return self.redirect(back, "a pinned path depends on it; unpin that first")
            deleted = write("DELETE FROM object WHERE store_path = ? AND cache_id = (SELECT id FROM cache WHERE name = ?)",
                            (target, name))
            start_gc()
            return self.redirect(back, f"deleted {deleted} path(s); its data is being freed")
        if action == "cleanup":
            return self.redirect(f"{base}/settings", f"deleted {cleanup(name)} unpinned build(s); free their data in Settings")
        if action == "visibility":
            attic("PATCH", f"/_api/v1/cache-config/{name}", {"is_public": form.get("public") == "1"})
            return self.redirect(f"{base}/settings", "visibility changed")
        if action == "pin":
            back = f"{base}/pins"
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
            return self.redirect(f"{base}/pins", f"unpinned {form.get('pin', '')}")
        if action == "token":
            sub, access, validity = form.get("sub", ""), form.get("access"), form.get("validity")
            if not USER_NAME.fullmatch(sub) or validity not in ("30d", "1y", "5y") or access not in ("pull", "push"):
                return self.redirect(f"{base}/settings", "token names are a-z, 0-9, _ and -")
            perms = [f"--pull={name}"] + ([f"--push={name}"] if access == "push" else [])
            token = make_token(sub, validity, perms)
            with ui_db() as db:
                db.execute("INSERT INTO tokens VALUES (?, ?, ?, ?, ?, ?)",
                           (name, sub, "pull and push" if access == "push" else "pull", validity,
                            datetime.now(timezone.utc).isoformat(), who["user"]))
            return self.reply(200, settings_page(who, find_cache(who, name), f"token for {sub}", token),
                              headers=[("Cache-Control", "no-store")])
        if action == "destroy":
            if form.get("confirm") != name:
                return self.redirect(f"{base}/settings", "type the cache name exactly to delete it")
            keep = pinned_paths(name)
            held = query("SELECT o.store_path FROM object o JOIN cache c ON c.id = o.cache_id WHERE c.name = ?", (name,))
            if any(path_ in keep for (path_,) in held):
                return self.redirect(f"{base}/settings", "this cache still holds pinned paths; unpin them first")
            attic("DELETE", f"/_api/v1/cache-config/{name}")
            start_gc()
            return self.redirect("/", f"deleted cache {name}")
        self.redirect(base, "unknown action")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    host, port = env("CACHE_LISTEN", "127.0.0.1:8082").rsplit(":", 1)
    threading.Thread(target=mirror_loop, daemon=True).start()
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()
