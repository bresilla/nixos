"""Mirror settings for gitea's repository, user and organisation settings pages.

Under /-/mirror/settings/: repo/<owner>/<repo> (links, their status, probes),
owner/<owner> (the owner's default remote namespace) and hostkey (trusting a
host's key, site admins only). Every request is checked by asking gitea for the
matching settings page with the visitor's own cookie. This process has no key: the
mirror service probes and syncs, this only writes the config it reads.
"""
import json
import os
import re
import secrets
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from common import (CONFIG, MODES, NAME, STATE, blocked, host_key_name, link_id, links_of, mode_blocked,
                    namespace_ok, namespace_of, parse_ssh, pinned_hosts, read_json, repo_by_name,
                    target_for, write_json, db)

GITEA = os.environ.get("GITEA", "http://127.0.0.1:3000")
ORIGIN = os.environ["ORIGIN"]
LISTEN = int(os.environ.get("PORT", "3101"))
PINNED = os.environ["KNOWN_HOSTS"]
PROBE_AGE = 3600
USERNAME = re.compile(r'<input id="username" name="name" value="([^"]+)"')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


opener = urllib.request.build_opener(NoRedirect)


def gitea_ok(path, cookie):
    """True when gitea serves this page to the visitor."""
    if not cookie:
        return False
    try:
        with opener.open(urllib.request.Request(f"{GITEA}{path}", headers={"Cookie": cookie}), timeout=10) as r:
            return r.status == 200
    except (urllib.error.URLError, OSError):
        return False


def signed_in_as(cookie):
    """The visitor's user name, read off their own profile settings form (the API wants a token)."""
    if not cookie:
        return None
    try:
        with opener.open(urllib.request.Request(f"{GITEA}/user/settings", headers={"Cookie": cookie}), timeout=10) as r:
            m = USERNAME.search(r.read(200_000).decode("utf-8", "replace"))
            return m[1].lower() if m and NAME.fullmatch(m[1]) else None
    except (urllib.error.URLError, OSError):
        return None


def owner_row(owner):
    with db() as conn:
        return conn.execute("select lower_name, type from user where lower_name = ?", (owner.lower(),)).fetchone()


def probe_result(probe_id, repo_id):
    if not isinstance(probe_id, str) or len(probe_id) != 32 or not all(c in "0123456789abcdef" for c in probe_id):
        return None
    p = read_json(f"{STATE}/probes/{probe_id}.json", None)
    return p if p and p.get("repo") == repo_id else None


def repo_view(repo, admin):
    states = read_json(f"{STATE}/links/{repo['id']}.json", {})
    links = []
    for link in links_of(repo["id"]):
        st = states.get(link_id(link["url"]), {})
        links.append({**link, "status": {k: st.get(k) for k in (
            "status", "message", "last_sync", "last_try", "lost", "diverged", "ahead", "extra")}})
    ns = namespace_of(repo["owner"])
    return {
        "repo": {k: repo[k] for k in ("owner", "name", "private", "mirror", "archived")},
        "blocked": blocked(repo),
        "namespace": ns,
        "suggested": target_for(ns, repo["name"]) if ns else None,
        "links": links,
        "admin": admin,
    }


def save_links(repo, links):
    write_json(f"{CONFIG}/links/{repo['id']}.json", {"owner": repo["owner"], "repo": repo["lower"], "links": links})
    kick(repo)


def kick(repo):
    os.makedirs(f"{CONFIG}/spool/sync", exist_ok=True)
    open(f"{CONFIG}/spool/sync/{repo['id']}", "w").close()


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def parts(self):
        parts = self.path.split("?")[0].removeprefix("/-/mirror/settings/").split("/")
        return parts if all(NAME.fullmatch(p) for p in parts) else None

    def body(self):
        length = min(int(self.headers.get("Content-Length", "0") or 0), 8192)
        try:
            given = json.loads(self.rfile.read(length) or b"{}")
            return given if isinstance(given, dict) else None
        except json.JSONDecodeError:
            return None

    def cookie(self):
        return self.headers.get("Cookie", "")

    def repo_checked(self, owner, name):
        if not gitea_ok(f"/{owner}/{name}/settings", self.cookie()):
            return self.reply(403, {"error": "not allowed"})
        repo = repo_by_name(owner, name)
        if not repo:
            return self.reply(404, {"error": "not found"})
        return repo

    def owner_checked(self, owner):
        row = owner_row(owner)
        if not row:
            return self.reply(404, {"error": "not found"})
        allowed = (gitea_ok(f"/org/{owner}/settings", self.cookie()) if row[1] == 1
                   else signed_in_as(self.cookie()) == row[0] or gitea_ok("/-/admin", self.cookie()))
        if not allowed:
            return self.reply(403, {"error": "not allowed"})
        return row

    def do_GET(self):
        p = self.parts()
        if p and p[0] == "repo" and len(p) == 3:
            repo = self.repo_checked(p[1], p[2])
            if repo:
                self.reply(200, repo_view(repo, gitea_ok("/-/admin", self.cookie())))
        elif p and p[0] == "repo" and len(p) == 5 and p[3] == "probe":
            repo = self.repo_checked(p[1], p[2])
            if repo:
                result = probe_result(p[4], repo["id"])
                self.reply(200, result or {"pending": True})
        elif p and p[0] == "owner" and len(p) == 2:
            row = self.owner_checked(p[1])
            if row:
                self.reply(200, {"owner": row[0], "org": row[1] == 1, "namespace": namespace_of(row[0])})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        # Same-site requests only, sent by the page's own script.
        if self.headers.get("Origin") != ORIGIN or self.headers.get("X-Mirror-Settings") != "1":
            return self.reply(403, {"error": "not allowed"})
        p = self.parts()
        given = self.body()
        if given is None:
            return self.reply(400, {"error": "bad request"})
        if p and p[0] == "repo" and len(p) == 3:
            repo = self.repo_checked(p[1], p[2])
            if repo:
                self.repo_post(repo, given)
        elif p and p[0] == "owner" and len(p) == 2:
            row = self.owner_checked(p[1])
            if not row:
                return
            ns = given.get("namespace")
            path = f"{CONFIG}/owners/{row[0]}.json"
            if ns in ("", None):
                if os.path.exists(path):
                    os.remove(path)
            elif isinstance(ns, str) and namespace_ok(ns.strip().rstrip("/")):
                write_json(path, {"namespace": ns.strip().rstrip("/"), "by": "page", "at": int(time.time())})
            else:
                return self.reply(400, {"error": "not an SSH namespace such as git@github.com:my-org"})
            self.reply(200, {"owner": row[0], "org": row[1] == 1, "namespace": namespace_of(row[0])})
        elif p == ["hostkey"]:
            self.hostkey(given)
        else:
            self.reply(404, {"error": "not found"})

    def repo_post(self, repo, given):
        action, url = given.get("action"), given.get("url")
        links = links_of(repo["id"])
        current = next((l for l in links if l["url"] == url), None)
        if action == "sync":
            kick(repo)
        elif action == "probe":
            if not parse_ssh(url):
                return self.reply(400, {"error": "not an SSH URL such as git@github.com:owner/repo.git"})
            spool = f"{CONFIG}/spool/probe"
            os.makedirs(spool, exist_ok=True)
            if len(os.listdir(spool)) > 20:
                return self.reply(429, {"error": "too many checks waiting; try again in a minute"})
            probe_id = secrets.token_hex(16)
            write_json(f"{spool}/{probe_id}.json", {"url": url, "repo": repo["id"]})
            return self.reply(200, {"probe": probe_id})
        elif action == "save":
            mode = given.get("mode")
            if mode not in MODES or not parse_ssh(url):
                return self.reply(400, {"error": "bad request"})
            why = blocked(repo) or ([mode_blocked(repo, mode)] if mode_blocked(repo, mode) else [])
            if why:
                return self.reply(400, {"error": f"not possible: {', '.join(why)}"})
            probe = probe_result(given.get("probe"), repo["id"]) if given.get("probe") else None
            if probe and (probe.get("url") != url or probe.get("at", 0) < time.time() - PROBE_AGE):
                probe = None
            checked = ({"read": probe["read"], "write": probe["write"], "modes": probe["modes"],
                        "reason": probe["reason"], "at": probe["at"]} if probe else (current or {}).get("probe"))
            if not checked or mode not in checked.get("modes", []):
                return self.reply(400, {"error": f"{mode} is not possible there: {(checked or {}).get('reason', 'press Check again first')}"})
            if current:
                current.update(mode=mode, probe=checked)
            else:
                if len(links) >= 10:
                    return self.reply(400, {"error": "ten targets at most"})
                links.append({"url": url, "mode": mode, "probe": checked, "by": "page", "added": int(time.time())})
            save_links(repo, links)
        elif action == "remove":
            if not current:
                return self.reply(404, {"error": "no such target"})
            save_links(repo, [l for l in links if l is not current])
        else:
            return self.reply(400, {"error": "bad request"})
        self.reply(200, repo_view(repo, gitea_ok("/-/admin", self.cookie())))

    def hostkey(self, given):
        if not gitea_ok("/-/admin", self.cookie()):
            return self.reply(403, {"error": "only site admins may trust a host key"})
        repo = repo_by_name(str(given.get("owner", "")), str(given.get("repo", "")))
        probe = probe_result(given.get("probe"), repo["id"]) if repo else None
        if not probe or probe.get("kind") != "hostkey" or not probe.get("hostkeys"):
            return self.reply(400, {"error": "no host key to trust"})
        _, host, port, _ = parse_ssh(probe["url"])
        name = host_key_name(host, port)
        if name in pinned_hosts(PINNED):
            return self.reply(400, {"error": f"{name}'s keys are pinned in the configuration"})
        path = f"{CONFIG}/known_hosts"
        try:
            lines = open(path).read().splitlines()
        except FileNotFoundError:
            lines = []
        for key in probe["hostkeys"]:
            parts = key["line"].split()
            if len(parts) >= 3 and parts[0] == name and key["line"] not in lines:
                lines.append(" ".join(parts[:3]))
        with open(f"{path}.tmp", "w") as f:
            f.write("".join(line + "\n" for line in lines))
        os.chmod(f"{path}.tmp", 0o664)
        os.replace(f"{path}.tmp", path)
        self.reply(200, {"trusted": name})

    def log_message(self, format, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", LISTEN), Handler).serve_forever()
