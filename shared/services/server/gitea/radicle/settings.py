"""Per-repository Radicle settings, for gitea's repository settings page.

GET and POST /-/radicle/settings/<owner>/<repo>. Only someone gitea lets into that
repository's settings may read or change them: every request is checked by asking
gitea for that page with the visitor's own cookie. The sync applies what is saved.
"""
import json
import os
import re
import sqlite3
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATABASE = os.environ["DATABASE"]
STATE = os.environ["SYNC_STATE"]
GITEA = os.environ.get("GITEA", "http://127.0.0.1:3000")
ORIGIN = os.environ["ORIGIN"]
LISTEN = int(os.environ.get("PORT", "3100"))
NAME = re.compile(r"[A-Za-z0-9._-]{1,100}")
SCOPES = ("all", "followed")
DEFAULTS = {"publish": True, "scope": "all"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


opener = urllib.request.build_opener(NoRedirect)


def may_manage(owner, repo, cookie):
    """True when gitea serves this repository's settings page to the visitor."""
    if not cookie:
        return False
    request = urllib.request.Request(f"{GITEA}/{owner}/{repo}/settings", headers={"Cookie": cookie})
    try:
        with opener.open(request, timeout=10) as response:
            return response.status == 200
    except urllib.error.HTTPError:
        return False


def repository(owner, repo):
    with sqlite3.connect(f"file:{DATABASE}?mode=ro", uri=True, timeout=5) as db:
        return db.execute(
            "select r.id, r.is_private, r.is_mirror, r.is_empty, u.visibility from repository r "
            "join user u on u.id = r.owner_id where lower(r.owner_name) = ? and r.lower_name = ?",
            (owner.lower(), repo.lower())).fetchone()


def read_json(path, fallback):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return fallback


def status(owner, repo, row):
    rid_file = f"{STATE}/repos/{row[0]}/rid"
    rid = open(rid_file).read().strip() if os.path.exists(rid_file) else None
    reasons = [text for flag, text in (
        (row[1], "the repository is private"), (row[2], "it is a mirror"),
        (row[3], "it has no commits yet"), (row[4] != 0, "its owner is not public")) if flag]
    published = read_json(f"{STATE}/public/{owner.lower()}/{repo.lower()}.json", {})
    return {
        "settings": {**DEFAULTS, **read_json(f"{STATE}/settings/{row[0]}.json", {})},
        "blocked": reasons,
        "rid": rid,
        "published": bool(published.get("rid")),
        "seeds": published.get("seeds", []),
        "updated": published.get("updated"),
    }


class Handler(BaseHTTPRequestHandler):
    def target(self):
        parts = self.path.split("?")[0].removeprefix("/-/radicle/settings/").split("/")
        if len(parts) != 2 or not all(NAME.fullmatch(p) for p in parts):
            return None
        return parts

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def checked(self):
        """The repository row when the visitor may manage it; replies otherwise."""
        parts = self.target()
        if not parts:
            return self.reply(404, {"error": "not found"})
        if not may_manage(*parts, self.headers.get("Cookie", "")):
            return self.reply(403, {"error": "not allowed"})
        row = repository(*parts)
        if not row:
            return self.reply(404, {"error": "not found"})
        return parts, row

    def do_GET(self):
        found = self.checked()
        if found:
            self.reply(200, status(*found[0], found[1]))

    def do_POST(self):
        # Same-site requests only, sent by the page's own script.
        if self.headers.get("Origin") != ORIGIN or self.headers.get("X-Radicle-Settings") != "1":
            return self.reply(403, {"error": "not allowed"})
        found = self.checked()
        if not found:
            return
        length = min(int(self.headers.get("Content-Length", "0")), 4096)
        try:
            given = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self.reply(400, {"error": "bad request"})
        (owner, repo), row = found
        path = f"{STATE}/settings/{row[0]}.json"
        settings = {**DEFAULTS, **read_json(path, {})}
        if isinstance(given.get("publish"), bool):
            settings["publish"] = given["publish"]
        if given.get("scope") in SCOPES:
            settings["scope"] = given["scope"]
        os.makedirs(f"{STATE}/settings", exist_ok=True)
        with open(f"{path}.tmp", "w") as f:
            json.dump(settings, f)
        os.replace(f"{path}.tmp", path)
        self.reply(200, status(owner, repo, row))

    def log_message(self, format, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", LISTEN), Handler).serve_forever()
