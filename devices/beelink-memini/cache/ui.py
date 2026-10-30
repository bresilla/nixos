"""Read-only web page over Attic's database: public caches and their recent paths."""

import base64
import html
import os
import re
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DB = os.environ["CACHE_DB"]
URL = os.environ["CACHE_URL"].rstrip("/")
HOST, PORT = os.environ.get("CACHE_LISTEN", "127.0.0.1:8082").rsplit(":", 1)

with open(os.environ["CACHE_LOGO"]) as f:
    LOGO = re.sub(r'fill="#[0-9a-fA-F]+"', 'fill="currentColor"', f.read().split("?>", 1)[-1])

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
main { max-width: 1000px; margin: 0 auto; padding: 20px; }
h2 { font-size: 15px; color: var(--accent); margin: 28px 0 8px; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid color-mix(in srgb, var(--accent) 25%, transparent); }
th { color: var(--mute); font-weight: normal; }
.num { text-align: right; white-space: nowrap; }
code { background: color-mix(in srgb, var(--accent) 12%, transparent); padding: 1px 5px; border-radius: 4px; word-break: break-all; }
.mute { color: var(--mute); }
input { font: inherit; color: inherit; width: 100%; box-sizing: border-box; padding: 8px 10px; border-radius: 6px;
  border: 1px solid color-mix(in srgb, var(--accent) 40%, transparent); background: transparent; outline-color: var(--accent); }
a { color: var(--accent); }
::selection { background: color-mix(in srgb, var(--accent) 40%, transparent); }
"""

# Same rule as gitea: a new hue on refresh, the saved one while clicking around.
SCRIPT = """
const reload = performance.getEntriesByType("navigation")[0]?.type === "reload";
let hue = localStorage.getItem("accent-hue");
if (reload || hue === null) { hue = Math.floor(Math.random() * 360); localStorage.setItem("accent-hue", hue); }
document.documentElement.style.setProperty("--accent", `hsl(${hue} 65% 50%)`);
"""


def size(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def public_key(keypair):
    # The stored keypair holds the secret; only its public half is ever shown.
    name, secret = keypair.split(":", 1)
    return f"{name}:{base64.b64encode(base64.b64decode(secret)[32:]).decode()}"


def query(sql, args=()):
    with sqlite3.connect(f"file:{DB}?mode=ro", uri=True) as db:
        return db.execute(sql, args).fetchall()


def page(search):
    e = html.escape
    caches = query(
        "SELECT c.name, c.keypair, COUNT(o.id), COALESCE(SUM(n.nar_size), 0), MAX(o.created_at) "
        "FROM cache c LEFT JOIN object o ON o.cache_id = c.id LEFT JOIN nar n ON n.id = o.nar_id "
        "WHERE c.is_public AND c.deleted_at IS NULL GROUP BY c.id ORDER BY c.name")
    paths = query(
        "SELECT c.name, o.store_path, n.nar_size, o.system, o.created_at "
        "FROM object o JOIN cache c ON c.id = o.cache_id JOIN nar n ON n.id = o.nar_id "
        "WHERE c.is_public AND c.deleted_at IS NULL AND o.store_path LIKE ? "
        "ORDER BY o.created_at DESC LIMIT 100", (f"%{search}%",))

    rows = []
    for name, keypair, count, total, last in caches:
        rows.append(
            f"<tr><td>{e(name)}</td><td class=num>{count}</td><td class=num>{size(total)}</td>"
            f"<td class=mute>{e((last or '-')[:16])}</td></tr>"
            f"<tr><td colspan=4 class=mute>substituter <code>{e(URL)}/{e(name)}</code><br>"
            f"public key <code>{e(public_key(keypair))}</code></td></tr>")
    caches_html = "".join(rows) or "<tr><td colspan=4 class=mute>no public caches yet</td></tr>"

    items = []
    for cache, path, nar, system, created in paths:
        digest, _, pname = path.removeprefix("/nix/store/").partition("-")
        items.append(
            f"<tr><td>{e(pname)} <span class=mute>{e(digest[:8])}</span></td><td>{e(cache)}</td>"
            f"<td class=mute>{e(system or '')}</td><td class=num>{size(nar)}</td>"
            f"<td class=mute>{e((created or '')[:16])}</td></tr>")
    paths_html = "".join(items) or "<tr><td colspan=5 class=mute>nothing found</td></tr>"

    return f"""<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1"><title>cache</title>
<script>{SCRIPT}</script><style>{STYLE}</style></head><body>
<header>{LOGO}<a href="/">cache</a></header><main>
<h2>caches</h2><table><tr><th>name</th><th class=num>paths</th><th class=num>size</th><th>last push</th></tr>{caches_html}</table>
<h2>paths</h2><form><input name=q value="{e(search)}" placeholder="search store paths" autofocus></form>
<table><tr><th>path</th><th>cache</th><th>system</th><th class=num>size</th><th>pushed</th></tr>{paths_html}</table>
</main></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path not in ("/", "/-/"):
            self.send_error(404)
            return
        try:
            body = page(parse_qs(url.query).get("q", [""])[0]).encode()
            self.send_response(200)
        except sqlite3.Error as err:
            body = f"database not ready: {html.escape(str(err))}".encode()
            self.send_response(503)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


ThreadingHTTPServer((HOST, int(PORT)), Handler).serve_forever()
