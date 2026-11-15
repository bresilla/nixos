"""net.bresilla.com: innernet's peers, groups and access, for net admins on id.bresilla.com.

Reads come from innernet's database and `wg show`; peers and groups change only
through innernet-server's own commands. Access between groups has no server
command, so it is written to the same table innernet's admin API writes.
"""

import site_ui
import hmac
import html
import ipaddress
import os
import re
import secrets
import sqlite3
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

env = os.environ.get
# Every network this server runs; the first path segment says which one a page is about.
NETS = env("NET_NAMES", "skynet0").split()
DATA = env("NET_DATA", "/var/lib/innernet-server")
SERVER = env("NET_SERVER", "innernet-server")
WG = env("NET_WG", "wg")
CSRF_KEY = secrets.token_bytes(32)
NAME = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")
EXPIRY = {"1h": "1 hour", "1d": "1 day", "7d": "7 days", "30d": "30 days"}
ONLINE = 180
ADMINS_ONLY = "only net admins on id.bresilla.com may use this page"
VIEW = threading.local()
lock = threading.Lock()
e = html.escape

SCRIPT = site_ui.SCRIPT + """
document.addEventListener("click", (event) => {
  const id = event.target.closest("[data-copy]")?.dataset.copy;
  if (id) navigator.clipboard?.writeText(document.getElementById(id).textContent);
  const save = event.target.closest("[data-save]");
  if (save) {
    const blob = new Blob([document.getElementById(save.dataset.save).textContent], {type: "application/toml"});
    const link = Object.assign(document.createElement("a"), {href: URL.createObjectURL(blob), download: save.dataset.name});
    link.click();
    URL.revokeObjectURL(link.href);
  }
});
"""


def query(sql, args=()):
    with sqlite3.connect(f"file:{DATA}/{VIEW.net}.db?mode=ro", uri=True, timeout=5) as db:
        return db.execute(sql, args).fetchall()


def write(sql, args=()):
    with sqlite3.connect(f"{DATA}/{VIEW.net}.db", timeout=5) as db:
        db.execute("PRAGMA foreign_keys = ON")
        db.execute(sql, args)


def server(*args):
    """One innernet-server command on this network; its error text on failure."""
    done = subprocess.run([SERVER, *args[:1], VIEW.net, *args[1:], "--yes"], capture_output=True, text=True, timeout=30)
    if done.returncode != 0:
        raise ValueError((done.stderr or done.stdout).strip().splitlines()[-1] if (done.stderr or done.stdout).strip()
                         else f"{args[0]} failed")
    return done.stdout


def live():
    """Per public key: endpoint, last handshake, bytes in and out."""
    done = subprocess.run([WG, "show", VIEW.net, "dump"], capture_output=True, text=True, timeout=10)
    peers = {}
    for line in done.stdout.splitlines()[1:]:
        key, _, endpoint, _, handshake, rx, tx, _ = (line.split("\t") + [""] * 8)[:8]
        peers[key] = {"endpoint": "" if endpoint == "(none)" else endpoint,
                      "handshake": int(handshake or 0), "rx": int(rx or 0), "tx": int(tx or 0)}
    return peers


def cidrs():
    return query("SELECT id, name, ip, prefix, parent FROM cidrs ORDER BY ip, prefix")


def groups():
    """The groups peers are put in: every CIDR but the network and the server's own."""
    return [c for c in cidrs() if c[4] is not None and c[1] != "innernet-server"]


def size(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024:
            return f"{n:.0f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def ago(t):
    if not t:
        return "never"
    s = int(time.time()) - t
    for unit, length in (("d", 86400), ("h", 3600), ("m", 60)):
        if s >= length:
            return f"{s // length}{unit} ago"
    return f"{s}s ago"

STYLE = site_ui.STYLE + """
td code, .nowrap { white-space: nowrap; }
td .sub { display: block; color: var(--mute); font-size: var(--site-font-small); margin-top: 2px; }
.dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: var(--s2); vertical-align: middle;
  background: transparent; border: 1px solid var(--mute); box-sizing: border-box; }
.dot.on { background: var(--ok); border-color: var(--ok); box-shadow: 0 0 0 3px color-mix(in srgb, var(--ok) 22%, transparent); }
.dot.wait { background: #d89614; border-color: #d89614; }
.dot.no { border-color: var(--bad); }
.stats.card { display: flex; }
.top { margin-bottom: var(--s5); }
.scroll + section.set, table + section.set, .card + .scroll { margin-top: var(--s6); }
.facts { display: flex; gap: var(--s2); align-items: center; flex-wrap: wrap; margin-top: var(--s2); color: var(--mute); font-size: var(--site-font-small); }
.facts a { color: var(--mute); text-decoration: none; padding: 1px var(--s2); border-radius: var(--site-radius-small); }
.facts a.on { color: var(--fg); background: color-mix(in srgb, var(--accent) var(--site-nav-active), transparent); }
.facts a:hover { color: var(--fg); background: var(--hover); }
.fields label.choice { display: flex; flex-direction: row; align-items: center; gap: var(--s2); color: var(--fg); font-size: var(--site-font-size); }
.fields label.choice input { width: auto; flex: none; }

details.menu { position: relative; display: inline-block; }
details.menu > summary { list-style: none; cursor: pointer; display: inline-flex; align-items: center; height: 28px;
  padding: 0 var(--s3); border: 1px solid var(--line-strong); border-radius: var(--site-radius-small);
  color: var(--accent-ink); font-size: var(--site-font-small); user-select: none; }
details.menu > summary::-webkit-details-marker { display: none; }
details.menu > summary:hover, details.menu[open] > summary { background: var(--hover); }
details.menu > div { position: absolute; right: 0; top: calc(100% + 6px); z-index: 5; width: 260px; display: grid; gap: var(--s2);
  padding: var(--s3); background: var(--raised); border: 1px solid var(--line); border-radius: var(--site-radius);
  box-shadow: 0 8px 24px color-mix(in srgb, var(--fg) 12%, transparent); text-align: left; }
details.menu form { display: flex; gap: var(--s2); margin: 0; }
details.menu input { flex: 1; min-width: 0; }
details.menu button { width: 100%; }
details.menu form:has(input) button { width: auto; }
table.matrix th, table.matrix td { text-align: center; }
table.matrix th:first-child, table.matrix td:first-child { text-align: left; }
table.matrix form { margin: 0; display: inline; }
table.matrix button { min-width: 72px; }
table.matrix button.ghost { color: var(--mute); }
.fields { display: grid; grid-template-columns: 1fr 1fr; gap: var(--s4); }
.fields label { display: grid; gap: var(--s1); font-size: var(--site-font-small); color: var(--mute); }
.fields .wide { grid-column: 1 / -1; }
.fields input, .fields select { width: 100%; box-sizing: border-box; }
@media (max-width: 720px) {
  .fields { grid-template-columns: 1fr; } .hide-narrow { display: none; } .top { align-items: flex-start; }
  .scroll { overflow-x: auto; } details.menu > div { position: static; width: auto; margin-top: var(--s1); }
}
"""


def network():
    """This network's range and the endpoint every peer reaches its server at."""
    rng = query("SELECT ip, prefix FROM cidrs WHERE parent IS NULL")
    end = query("SELECT endpoint FROM peers WHERE name = 'innernet-server'")
    return (f"{rng[0][0]}/{rng[0][1]}" if rng else "", end[0][0] if end and end[0][0] else "")


def layout(title, body, nav, flash=""):
    links = [("peers", "/", "Peers"), ("groups", "/-/groups", "Groups"), ("access", "/-/access", "Access")]
    return site_ui.page(site="net", title=title, body=body, links=links, active=nav, name=getattr(VIEW, "name", None),
                        here=getattr(VIEW, "path", "/"), flash=flash, style=STYLE, script=SCRIPT)


def head(title, action=""):
    """Title, the network it is about (and the others, to switch), its range and endpoint."""
    rng, end = network()
    nets = "".join(f'<a href="/{n}/" class="{"on" if n == VIEW.net else ""}">{e(n)}</a>' for n in NETS)
    facts = " <span>·</span> ".join([nets, f'<span>{e(rng)}</span>'] + ([f'<span>{e(end)}</span>'] if end else []))
    return f'<div class=top><div><h1>{e(title)}</h1><div class=facts>{facts}</div></div>{action}</div>'


def csrf(who):
    return f'<input type=hidden name=csrf value="{e(who["csrf"])}">'


def status(disabled, redeemed, expires, seen):
    """A dot and a word for where a peer stands, and when that was last true."""
    if disabled:
        return '<span class="dot no"></span>disabled', ""
    if not redeemed:
        return '<span class="dot wait"></span>invited', f'until {time.strftime("%b %d %H:%M", time.localtime(expires or 0))}'
    if seen and time.time() - seen < ONLINE:
        return '<span class="dot on"></span>online', f"handshake {ago(seen)}"
    return '<span class=dot></span>offline', (f"last seen {ago(seen)}" if seen else "not seen yet")


def menu(*items):
    return f'<details class=menu><summary>Manage</summary><div>{"".join(items)}</div></details>'


def peers_page(who, flash):
    wg = live()
    names = {c[0]: c[1] for c in cidrs()}
    rows = query("SELECT name, ip, cidr_id, public_key, is_disabled, is_redeemed, invite_expires, is_admin "
                 "FROM peers WHERE name <> 'innernet-server'")
    rows.sort(key=lambda r: ipaddress.ip_address(r[1]))
    online = invited = disabled_count = 0
    body = ""
    for name, ip, cidr_id, key, disabled, redeemed, expires, admin in rows:
        info = wg.get(key, {})
        word, when = status(disabled, redeemed, expires, info.get("handshake", 0))
        online += "dot on" in word
        invited += "dot wait" in word
        disabled_count += bool(disabled)
        toggle = "enable" if disabled else "disable"
        actions = menu(
            f'<form method=post action="/-/peer/{quote(name)}/rename">{csrf(who)}'
            f'<input name=new required placeholder="new name" pattern="[a-z0-9][a-z0-9-]*"><button class=small>Rename</button></form>',
            f'<form method=post action="/-/peer/{quote(name)}/{toggle}">{csrf(who)}'
            f'<button class="small {"" if disabled else "danger"}">{toggle.capitalize()} {e(name)}</button></form>')
        traffic = f'↓ {size(info["rx"])} · ↑ {size(info["tx"])}' if info.get("rx") or info.get("tx") else ""
        body += (f'<tr><td><b>{e(name)}</b>{" <span class=pill>admin</span>" if admin else ""}'
                 f'<span class=sub>{e(names.get(cidr_id, "?"))}</span></td>'
                 f'<td><code>{e(ip)}</code></td>'
                 f'<td class=nowrap>{word}<span class=sub>{e(when)}</span></td>'
                 f'<td class="mute nowrap hide-narrow">{e(info.get("endpoint", ""))}</td>'
                 f'<td class="num mute nowrap hide-narrow">{traffic}</td>'
                 f'<td class=num>{actions}</td></tr>')
    stats = (f'<div class="card stats"><div><b>{online}</b>online</div><div><b>{len(rows)}</b>peers</div>'
             f'<div><b>{invited}</b>invited</div><div><b>{disabled_count}</b>disabled</div></div>')
    table = (f'<div class=scroll><table><tr><th>Peer</th><th>Address</th><th>Status</th><th class=hide-narrow>Endpoint</th>'
             f'<th class="num hide-narrow">Traffic</th><th></th></tr>{body}</table></div>') if rows else \
        '<div class="card empty">No peers yet. Invite the first one.</div>'
    action = '<a href="/-/new"><button>New peer</button></a>'
    return layout("peers", head("Peers", action) + stats + table, "peers", flash)


def new_page(who, flash, invite="", peer=""):
    if invite:
        body = (f'<div class=crumbs><a href="/">Peers ›</a></div>{head(f"Invitation for {peer}")}'
                '<div class=flash>Save it now: it holds the peer\'s first key and is not shown again.</div>'
                f'{step(1, "Download the invitation")}'
                f'<p><button data-save=invite data-name="{e(peer)}.toml">Download {e(peer)}.toml</button></p>'
                f'{step(2, "Install it on the machine")}'
                f'<div class=cmd><button class=iconbtn title=copy data-copy=install>{site_ui.ICONS["copy"]}</button>'
                f'<pre id=install>sudo innernet install --default-name --no-write-hosts {e(peer)}.toml\n'
                f'sudo systemctl start innernet-{e(VIEW.net)}</pre></div>'
                f'{step(3, "Keep its identity in gopass")}'
                f'<div class=cmd><button class=iconbtn title=copy data-copy=keep>{site_ui.ICONS["copy"]}</button>'
                f'<pre id=keep>sudo cat /etc/innernet/{e(VIEW.net)}.conf | gopass insert -m services/{e(peer)}/innernet/{e(VIEW.net)}</pre></div>'
                f'<pre id=invite hidden>{e(invite)}</pre><p><a href="/">Back to peers</a></p>')
        return layout("new peer", body, "peers", flash)
    options = "".join(f'<option value="{e(c[1])}">{e(c[1])} · {e(c[2])}/{c[3]}</option>' for c in groups())
    expiry = "".join(f'<option value="{k}"{" selected" if k == "7d" else ""}>{v}</option>' for k, v in EXPIRY.items())
    body = (f'<div class=crumbs><a href="/">Peers ›</a></div>{head("New peer")}'
            f'<form method=post action="/-/new" class=card style="max-width:720px;margin-top:var(--s6)">{csrf(who)}<div class=fields>'
            '<label class=wide>Name, as the machine\'s hostname'
            '<input name=name required placeholder="fair" pattern="[a-z0-9][a-z0-9-]*" autofocus></label>'
            f'<label>Group<select name=group required>{options}</select></label>'
            f'<label>Invitation valid for<select name=expires>{expiry}</select></label>'
            '<label class="choice wide"><input type=checkbox name=admin value=1> Admin: may add peers and groups from it</label>'
            '</div><p><button>Make invitation</button></p></form>'
            '<p class=mute>The peer gets the next free address in its group. Its invitation holds a first key, '
            'which the machine replaces with its own as it joins.</p>')
    return layout("new peer", body, "peers", flash)


def step(number, title):
    return f'<div class=step><span>STEP {number}</span>{e(title)}</div>'


def reaches():
    """For each group id, the names of the groups it reaches."""
    names = {c[0]: c[1] for c in cidrs()}
    out = {}
    for a, b in query("SELECT cidr_id_1, cidr_id_2 FROM associations"):
        out.setdefault(a, []).append(names.get(b, "?"))
        out.setdefault(b, []).append(names.get(a, "?"))
    return out


def groups_page(who, flash):
    count = dict(query("SELECT cidr_id, COUNT(*) FROM peers GROUP BY cidr_id"))
    links = reaches()
    rows = "".join(
        f'<tr><td><b>{e(n)}</b></td><td><code>{e(ip)}/{p}</code></td><td class=num>{count.get(i, 0)}</td>'
        f'<td class=mute>{e(", ".join(sorted(links.get(i, []))) or "only itself")}</td><td class=num>'
        + menu(f'<form method=post action="/-/group/{quote(n)}/rename">{csrf(who)}'
               f'<input name=new required placeholder="new name" pattern="[a-z0-9][a-z0-9-]*"><button class=small>Rename</button></form>',
               f'<form method=post action="/-/group/{quote(n)}/delete">{csrf(who)}'
               f'<button class="small danger"{" disabled title=\"it still has peers\"" if count.get(i) else ""}>Delete {e(n)}</button></form>')
        + '</td></tr>' for i, n, ip, p, parent in groups())
    parents = "".join(f'<option value="{e(c[1])}">{e(c[1])} · {e(c[2])}/{c[3]}</option>'
                      for c in cidrs() if c[1] != "innernet-server")
    table = (f'<table><tr><th>Group</th><th>Range</th><th class=num>Peers</th><th>Reaches</th><th></th></tr>{rows}</table>'
             if rows else '<div class="card empty">No groups yet.</div>')
    body = (head("Groups") + '<p class=mute>A group is an address range; a peer gets the next free address in its group. '
            'Who reaches whom is set under Access.</p>' + table +
            f'<section class=set><h3>new group</h3><div><form method=post action="/-/groups">{csrf(who)}<div class=fields>'
            '<label>Name<input name=name required placeholder="lab" pattern="[a-z0-9][a-z0-9-]*"></label>'
            '<label>Range<input name=cidr required placeholder="10.20.5.0/24"></label>'
            f'<label class=wide>Inside<select name=parent>{parents}</select></label>'
            '</div><p><button>Add group</button></p></form></div></section>')
    return layout("groups", body, "groups", flash)


def access_page(who, flash):
    every = groups()
    pairs = {}
    for i, a, b in query("SELECT id, cidr_id_1, cidr_id_2 FROM associations"):
        pairs[(a, b)] = pairs[(b, a)] = i

    def cell(row, col):
        if row == col:
            return '<td class=mute>always</td>'
        if (row, col) in pairs:
            return (f'<td><form method=post action="/-/access/{pairs[(row, col)]}/delete">{csrf(who)}'
                    '<button class=small title="click to remove">✓ reaches</button></form></td>')
        a, b = sorted((row, col))
        return (f'<td><form method=post action="/-/access">{csrf(who)}<input type=hidden name=a value={a}>'
                f'<input type=hidden name=b value={b}><button class="small ghost">allow</button></form></td>')

    head_row = "".join(f'<th>{e(n)}</th>' for _, n, *_ in every)
    rows = "".join(f'<tr><td><b>{e(n)}</b></td>{"".join(cell(i, j) for j, *_ in every)}</tr>' for i, n, *_ in every)
    table = (f'<div class=scroll><table class=matrix><tr><th></th>{head_row}</tr>{rows}</table></div>' if every
             else '<div class="card empty">No groups yet.</div>')
    body = (head("Access") + '<p class=mute>Peers in one group always reach each other, and every peer reaches the server. '
            'Between groups, click a cell to allow or remove; it works both ways.</p>' + table)
    return layout("access", body, "access", flash)


def within(body):
    """The page's own links and forms, under the network it is about."""
    return OWN_LINK.sub(lambda m: f'{m[1]}="/{VIEW.net}/', body)

OWN_LINK = re.compile(r'(href|action)="/(?!oauth2|(?:' + "|".join(map(re.escape, NETS)) + r')/)')


class Handler(BaseHTTPRequestHandler):
    def route(self):
        """Takes the network off the path; False when there is no such network."""
        url = urlparse(self.path)
        first, _, rest = url.path.lstrip("/").partition("/")
        VIEW.net = first if first in NETS else NETS[0]
        return first in NETS, "/" + rest, url

    def reply(self, code, body, headers=()):
        body = within(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cache-Control", "no-store")
        for header in headers:
            self.send_header(*header)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, to, flash=""):
        self.reply(303, "", [("Location", f"/{VIEW.net}{to}" + ("?msg=" + quote(flash) if flash else ""))])

    def who(self):
        # The login proxy in front passes the name and the net_role claim; Caddy
        # strips both from what visitors send.
        name = self.headers.get("X-Forwarded-Preferred-Username") or self.headers.get("X-Forwarded-User")
        VIEW.name, VIEW.path = name or None, self.path
        if not name or "admin" not in self.headers.get("X-Forwarded-Groups", "").split(","):
            return None
        return {"user": name, "csrf": hmac.new(CSRF_KEY, name.encode(), "sha256").hexdigest()}

    def form(self):
        length = min(int(self.headers.get("Content-Length", "0")), 16384)
        return {k: v[0].strip() for k, v in parse_qs(self.rfile.read(length).decode(errors="replace")).items()}

    def do_GET(self):
        known, path, url = self.route()
        flash = parse_qs(url.query).get("msg", [""])[0]
        who = self.who()
        if not who:
            return self.reply(403, layout("sign in", f'<div class="card empty">{ADMINS_ONLY}</div>', "peers"))
        if not known:
            return self.redirect("/") if url.path == "/" else self.reply(
                404, layout("not found", '<div class="card empty">not found</div>', "peers"))
        try:
            page = {"/": peers_page, "/-/new": new_page, "/-/groups": groups_page, "/-/access": access_page}.get(path)
            if page:
                return self.reply(200, page(who, flash))
            self.reply(404, layout("not found", '<div class="card empty">not found</div>', "peers"))
        except (sqlite3.Error, OSError, subprocess.SubprocessError) as err:
            self.reply(503, layout("not ready", f'<div class="card empty">innernet is not ready: {e(str(err))}</div>', "peers"))

    def do_POST(self):
        known, path, _ = self.route()
        form = self.form()
        who = self.who()
        if not known or not who or not hmac.compare_digest(form.get("csrf", ""), who["csrf"]):
            return self.redirect("/", ADMINS_ONLY)
        back = {"group": "/-/groups", "groups": "/-/groups", "access": "/-/access"}.get((path.split("/") + ["", "", ""])[2], "/")
        try:
            with lock:
                self.manage(path, form, who)
        except (ValueError, sqlite3.Error, OSError, subprocess.SubprocessError) as err:
            self.redirect(back, f"failed: {err}")

    def manage(self, path, form, who):
        parts = path.split("/")[2:]
        if parts == ["new"]:
            name, group, expires = form.get("name", ""), form.get("group", ""), form.get("expires", "7d")
            if not NAME.fullmatch(name) or expires not in EXPIRY or group not in {c[1] for c in groups()}:
                raise ValueError("names are a-z, 0-9 and -, in a group from the list")
            with tempfile.TemporaryDirectory() as tmp:
                out = os.path.join(tmp, "invite.toml")
                server("add-peer", "--name", name, "--cidr", group, "--auto-ip", "--admin",
                       "true" if form.get("admin") else "false", "--invite-expires", expires, "--save-config", out)
                with open(out) as f:
                    invite = f.read()
            return self.reply(200, new_page(who, f"invited {name}", invite, name))
        if len(parts) == 3 and parts[0] == "peer" and parts[2] in ("enable", "disable", "rename"):
            name = parts[1]
            if not NAME.fullmatch(name) or name == "innernet-server":
                raise ValueError("no such peer")
            if parts[2] == "rename":
                new = form.get("new", "")
                if not NAME.fullmatch(new):
                    raise ValueError("names are a-z, 0-9 and -")
                server("rename-peer", "--name", name, "--new-name", new)
                return self.redirect("/", f"renamed {name} to {new}")
            server(f"{parts[2]}-peer", "--name", name)
            return self.redirect("/", f"{parts[2]}d {name}")
        if parts == ["groups"]:
            name, cidr, parent = form.get("name", ""), form.get("cidr", ""), form.get("parent", "")
            if not NAME.fullmatch(name):
                raise ValueError("names are a-z, 0-9 and -")
            ipaddress.ip_network(cidr)
            server("add-cidr", "--name", name, "--cidr", cidr, "--parent", parent)
            return self.redirect("/-/groups", f"added group {name}")
        if len(parts) == 3 and parts[0] == "group" and parts[2] in ("rename", "delete"):
            name = parts[1]
            if name not in {c[1] for c in groups()}:
                raise ValueError("no such group")
            if parts[2] == "rename":
                new = form.get("new", "")
                if not NAME.fullmatch(new):
                    raise ValueError("names are a-z, 0-9 and -")
                server("rename-cidr", "--name", name, "--new-name", new)
                return self.redirect("/-/groups", f"renamed {name} to {new}")
            if query("SELECT 1 FROM associations a JOIN cidrs c ON c.id IN (a.cidr_id_1, a.cidr_id_2) WHERE c.name = ?", (name,)):
                raise ValueError(f"remove {name}'s access first")
            server("delete-cidr", "--name", name)
            return self.redirect("/-/groups", f"deleted group {name}")
        if parts == ["access"]:
            ids = {c[0] for c in groups()}
            a, b = sorted(int(form.get(k, "0")) if form.get(k, "").isdigit() else 0 for k in ("a", "b"))
            if a not in ids or b not in ids or a == b:
                raise ValueError("pick two different groups")
            if query("SELECT 1 FROM associations WHERE (cidr_id_1, cidr_id_2) IN ((?, ?), (?, ?))", (a, b, b, a)):
                raise ValueError("those two already reach each other")
            write("INSERT INTO associations (cidr_id_1, cidr_id_2) VALUES (?, ?)", (a, b))
            return self.redirect("/-/access", "allowed")
        if len(parts) == 3 and parts[0] == "access" and parts[1].isdigit() and parts[2] == "delete":
            write("DELETE FROM associations WHERE id = ?", (int(parts[1]),))
            return self.redirect("/-/access", "removed")
        raise ValueError("unknown action")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    host, port = env("NET_LISTEN", "127.0.0.1:8092").rsplit(":", 1)
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()
