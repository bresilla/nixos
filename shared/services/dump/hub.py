"""dump's hub: hands the manager the target list (written by the status page) and keeps
what the manager reports back: its key, each target's state (with the disks a new one
can pick from) and each target's report. The manager is known by its address alone.
"""

import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from fields import valid  # noqa: E402

STATE = Path(os.environ.get("DUMP_STATE", "/var/lib/dump"))
REPORTS = Path(os.environ.get("DUMP_REPORTS", "/var/lib/status"))
MANAGER = os.environ["DUMP_MANAGER"]
HOST, PORT = os.environ["DUMP_LISTEN"].rsplit(":", 1)
lock = threading.Lock()


def read(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write(path, data):
    new = path.with_name(path.name + ".new")
    new.unlink(missing_ok=True)
    fd = os.open(new, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=1)
    new.replace(path)


def targets():
    """The targets split into the usable ones and what is wrong with the rest."""
    good, bad = {}, {}
    for name, t in read(STATE / "targets.json", {}).items():
        problem = valid(name, t)
        if problem:
            bad[name] = problem
        else:
            good[name] = t
    return good, bad


class Hub(BaseHTTPRequestHandler):
    def send(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def payload(self):
        length = min(int(self.headers.get("Content-Length", "0") or 0), 1 << 20)
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return None

    def from_manager(self):
        return self.client_address[0] == MANAGER

    def do_GET(self):
        if not self.from_manager():
            return self.send(403, {"error": "not the manager"})
        if self.path == "/config":
            return self.send(200, {"targets": targets()[0]})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        data = self.payload()
        if not self.from_manager():
            return self.send(403, {"error": "not the manager"})
        if not isinstance(data, dict):
            return self.send(400, {"error": "bad request"})
        good, bad = targets()
        if self.path == "/agent":
            states = {n: s for n, s in (data.get("targets") or {}).items() if n in good and isinstance(s, dict)}
            states.update({n: {"state": "error", "detail": f"not used: {why}", "at": int(time.time())} for n, why in bad.items()})
            with lock:
                write(STATE / "agents.json", {"manager": {"at": int(time.time()), "key": str(data.get("key", ""))[:300], "targets": states}})
            return self.send(200, {"ok": True})
        m = re.fullmatch(r"/report/([a-z0-9][a-z0-9-]{0,30})", self.path)
        if m:
            if m[1] not in good:
                return self.send(403, {"error": "no such target"})
            write(REPORTS / f"dump-{m[1]}.json", data)
            return self.send(200, {"ok": True})
        self.send(404, {"error": "not found"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, int(PORT)), Hub).serve_forever()
