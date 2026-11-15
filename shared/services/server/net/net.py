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
NET = env("NET_NAME", "skynet0")
DB = env("NET_DB", f"/var/lib/innernet-server/{NET}.db")
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
    with sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5) as db:
        return db.execute(sql, args).fetchall()


def write(sql, args=()):
    with sqlite3.connect(DB, timeout=5) as db:
        db.execute("PRAGMA foreign_keys = ON")
        db.execute(sql, args)


def server(*args):
    """One innernet-server command on this network; its error text on failure."""
    done = subprocess.run([SERVER, *args[:1], NET, *args[1:], "--yes"], capture_output=True, text=True, timeout=30)
    if done.returncode != 0:
        raise ValueError((done.stderr or done.stdout).strip().splitlines()[-1] if (done.stderr or done.stdout).strip()
                         else f"{args[0]} failed")
    return done.stdout


def live():
    """Per public key: endpoint, last handshake, bytes in and out."""
    done = subprocess.run([WG, "show", NET, "dump"], capture_output=True, text=True, timeout=10)
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


def layout(title, body, nav, flash=""):
    links = [("peers", "/", "Peers"), ("groups", "/-/groups", "Groups"), ("access", "/-/access", "Access")]
    return site_ui.page(site="net", title=title, body=body, links=links, active=nav, name=getattr(VIEW, "name", None),
                        here=getattr(VIEW, "path", "/"), flash=flash, script=SCRIPT)


def csrf(who):
    return f'<input type=hidden name=csrf value="{e(who["csrf"])}">'


def state(peer, wg):
    _, _, _, key, disabled, redeemed, expires, _ = peer
    if disabled:
        return '<span class=pill>disabled</span>'
    if not redeemed:
        return f'<span class=pill>invited</span> <span class=mute>until {time.strftime("%Y-%m-%d %H:%M", time.localtime(expires or 0))}</span>'
    seen = wg.get(key, {}).get("handshake", 0)
    return ('<span class=pill>online</span>' if seen and time.time() - seen < ONLINE else '<span class=mute>offline</span>')


def peers_page(who, flash):
    wg = live()
    names = {c[0]: c[1] for c in cidrs()}
    rows = query("SELECT p.name, p.ip, p.cidr_id, p.public_key, p.is_disabled, p.is_redeemed, p.invite_expires, p.is_admin "
                 "FROM peers p ORDER BY p.ip")
    body = ""
    for peer in rows:
        name, ip, cidr_id, key, disabled, *_ , admin = peer
        info = wg.get(key, {})
        server_row = name == "innernet-server"
        toggle = "" if server_row else (
            f'<form class=inline method=post action="/-/peer/{quote(name)}/{"enable" if disabled else "disable"}">{csrf(who)}'
            f'<button class="small ghost">{"Enable" if disabled else "Disable"}</button></form>')
        rename = "" if server_row else (
            f'<form class=inline method=post action="/-/peer/{quote(name)}/rename">{csrf(who)}'
            f'<input name=new size=10 placeholder="new name" required><button class="small ghost">Rename</button></form>')
        body += (f'<tr><td><b>{e(name)}</b>{" <span class=pill>admin</span>" if admin else ""}</td><td><code>{e(ip)}</code></td>'
                 f'<td>{e(names.get(cidr_id, "?"))}</td><td>{state(peer, wg) if not server_row else "<span class=pill>server</span>"}</td>'
                 f'<td class=mute>{e(info.get("endpoint", ""))}</td><td class=mute>{e(ago(info.get("handshake", 0))) if info else ""}</td>'
                 f'<td class="num mute">{size(info["rx"]) + " / " + size(info["tx"]) if info else ""}</td>'
                 f'<td class=num>{rename}{toggle}</td></tr>')
    table = (f'<table><tr><th>Peer</th><th>Address</th><th>Group</th><th>State</th><th>Endpoint</th><th>Handshake</th>'
             f'<th class=num>In / out</th><th></th></tr>{body}</table>')
    head = (f'<div class=pagehead><h1>Peers</h1><a href="/-/new"><button>New peer</button></a></div>'
            f'<p class=mute>Network <code>{e(NET)}</code>. Peers are never deleted, only disabled; '
            f'an invitation not used before it expires goes away by itself.</p>')
    return layout("peers", head + table, "peers", flash)


def new_page(who, flash, invite="", peer=""):
    if invite:
        body = (f'<div class=pagehead><h1>Invitation for {e(peer)}</h1></div>'
                '<div class=flash>Save it now: it holds the peer\'s first key and is not shown again.</div>'
                f'<p><button data-save=invite data-name="{e(peer)}.toml">Download {e(peer)}.toml</button></p>'
                '<p class=mute>Copy the file to the new machine, then run there:</p>'
                f'<div class=cmd><button class=iconbtn title=copy data-copy=install>{site_ui.ICONS["copy"]}</button>'
                f'<pre id=install>sudo innernet install --default-name --no-write-hosts {e(peer)}.toml</pre></div>'
                f'<pre id=invite hidden>{e(invite)}</pre>'
                '<p class=mute>Afterwards, keep its <code>/etc/innernet/' + e(NET) + '.conf</code> in gopass so a reinstall '
                'keeps the same identity.</p><p><a href="/">Back to peers</a></p>')
        return layout("new peer", body, "peers", flash)
    options = "".join(f'<option value="{e(c[1])}">{e(c[1])} ({e(c[2])}/{c[3]})</option>' for c in groups())
    expiry = "".join(f'<option value="{k}"{" selected" if k == "7d" else ""}>{v}</option>' for k, v in EXPIRY.items())
    body = ('<div class=crumbs><a href="/">Peers ›</a></div><div class=pagehead><h1>New peer</h1></div>'
            f'<form method=post action="/-/new" class=card style="max-width:620px">{csrf(who)}'
            '<p><label>Name<br><input name=name class=wide required placeholder="e.g. fair" pattern="[a-z0-9][a-z0-9-]*"></label></p>'
            f'<p><label>Group<br><select name=group required>{options}</select></label></p>'
            f'<p><label>Invitation valid for<br><select name=expires>{expiry}</select></label></p>'
            '<p><label class=choice><input type=checkbox name=admin value=1> Admin: may add peers and groups itself</label></p>'
            '<p><button>Make invitation</button></p></form>')
    return layout("new peer", body, "peers", flash)


def groups_page(who, flash):
    every = cidrs()
    names = {c[0]: c[1] for c in every}
    count = dict(query("SELECT cidr_id, COUNT(*) FROM peers GROUP BY cidr_id"))
    rows = "".join(
        f'<tr><td><b>{e(n)}</b></td><td><code>{e(ip)}/{p}</code></td><td>{e(names.get(parent, ""))}</td>'
        f'<td class=num>{count.get(i, 0)}</td><td class=num>'
        f'<form class=inline method=post action="/-/group/{quote(n)}/rename">{csrf(who)}'
        f'<input name=new size=10 placeholder="new name" required><button class="small ghost">Rename</button></form>'
        f'<form class=inline method=post action="/-/group/{quote(n)}/delete">{csrf(who)}'
        f'<button class="small danger">Delete</button></form></td></tr>'
        for i, n, ip, p, parent in groups())
    parents = "".join(f'<option value="{e(c[1])}">{e(c[1])} ({e(c[2])}/{c[3]})</option>'
                      for c in every if c[1] != "innernet-server")
    body = (f'<div class=pagehead><h1>Groups</h1></div>'
            '<p class=mute>Each group is an address range; a peer gets the next free address in its group. '
            'A group with peers in it cannot be deleted.</p>'
            f'<table><tr><th>Group</th><th>Range</th><th>Inside</th><th class=num>Peers</th><th></th></tr>{rows}</table>'
            f'<h2>New group</h2><form class=row method=post action="/-/groups">{csrf(who)}'
            '<input name=name required placeholder="name" pattern="[a-z0-9][a-z0-9-]*">'
            '<input name=cidr required placeholder="10.20.5.0/24">'
            f'<select name=parent>{parents}</select><button>Add group</button></form>')
    return layout("groups", body, "groups", flash)


def access_page(who, flash):
    names = {c[0]: c[1] for c in cidrs()}
    pairs = query("SELECT id, cidr_id_1, cidr_id_2 FROM associations ORDER BY id")
    rows = "".join(
        f'<tr><td><b>{e(names.get(a, "?"))}</b> ↔ <b>{e(names.get(b, "?"))}</b></td><td class=num>'
        f'<form class=inline method=post action="/-/access/{i}/delete">{csrf(who)}<button class="small danger">Remove</button>'
        f'</form></td></tr>' for i, a, b in pairs) or '<tr><td colspan=2 class=mute>no group reaches another yet</td></tr>'
    options = "".join(f'<option value="{c[0]}">{e(c[1])}</option>' for c in groups())
    body = ('<div class=pagehead><h1>Access</h1></div>'
            '<p class=mute>Peers in the same group always reach each other, and every peer reaches the server. '
            'Between two groups, only the pairs here.</p>'
            f'<table><tr><th>Groups that reach each other</th><th></th></tr>{rows}</table>'
            f'<h2>Allow</h2><form class=row method=post action="/-/access">{csrf(who)}'
            f'<select name=a>{options}</select><span>↔</span><select name=b>{options}</select><button>Allow</button></form>')
    return layout("access", body, "access", flash)


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body, headers=()):
        body = body.encode()
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
        self.reply(303, "", [("Location", to + ("?msg=" + quote(flash) if flash else ""))])

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
        url = urlparse(self.path)
        flash = parse_qs(url.query).get("msg", [""])[0]
        who = self.who()
        if not who:
            return self.reply(403, layout("sign in", f'<div class="card empty">{ADMINS_ONLY}</div>', "peers"))
        try:
            page = {"/": peers_page, "/-/new": new_page, "/-/groups": groups_page, "/-/access": access_page}.get(url.path)
            if page:
                return self.reply(200, page(who, flash))
            self.reply(404, layout("not found", '<div class="card empty">not found</div>', "peers"))
        except (sqlite3.Error, OSError, subprocess.SubprocessError) as err:
            self.reply(503, layout("not ready", f'<div class="card empty">innernet is not ready: {e(str(err))}</div>', "peers"))

    def do_POST(self):
        path, form = urlparse(self.path).path, self.form()
        who = self.who()
        if not who or not hmac.compare_digest(form.get("csrf", ""), who["csrf"]):
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
