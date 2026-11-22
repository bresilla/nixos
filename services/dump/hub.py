"""dump's hub on hive: hands nest's manager the target list (written by
status.bresilla.com), and keeps what the manager reports back: its key, each target's
state (with the disks a new one can pick from) and each target's report.

The manager is known only by the address it connects from (DUMP_AGENTS).
"""

import json
import os
import re
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATE = Path(os.environ.get("DUMP_STATE", "/var/lib/dump"))
REPORTS = Path(os.environ.get("DUMP_REPORTS", "/var/lib/status"))
AGENTS = json.loads(os.environ["DUMP_AGENTS"])
SOURCE = json.loads(os.environ["DUMP_SOURCE"])
LISTEN = os.environ.get("DUMP_LISTEN", "127.0.0.1:9103").split()
BY_ADDRESS = {address: machine for machine, addresses in AGENTS.items() for address in addresses}
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,30}")
lock = threading.Lock()


def read(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write(path, data):
    new = path.with_name(path.name + ".new")
    new.write_text(json.dumps(data, indent=1))
    os.chmod(new, 0o644)
    new.replace(path)


def targets():
    return read(STATE / "targets.json", {})


def runs_on(target):
    """Every target is served from nest: disks over SSH, restic directly."""
    return SOURCE["host"] if target else None


class Hub(BaseHTTPRequestHandler):
    def machine(self):
        return BY_ADDRESS.get(self.client_address[0])

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

    def do_GET(self):
        me = self.machine()
        if not me:
            return self.send(403, {"error": "unknown machine"})
        if self.path == "/config":
            mine = {n: t for n, t in targets().items() if runs_on(t) == me}
            return self.send(200, {"machine": me, "source": SOURCE, "targets": mine})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        me = self.machine()
        data = self.payload()
        if not me or not isinstance(data, dict):
            return self.send(403 if not me else 400, {"error": "unknown machine" if not me else "bad request"})
        if self.path == "/agent":
            with lock:
                agents = read(STATE / "agents.json", {})
                agents[me] = {
                    "at": int(time.time()),
                    "key": str(data.get("key", ""))[:300],
                    "targets": {n: s for n, s in (data.get("targets") or {}).items()
                                if NAME.fullmatch(n) and runs_on(targets().get(n, {})) == me},
                }
                write(STATE / "agents.json", agents)
            return self.send(200, {"ok": True})
        m = re.fullmatch(r"/report/([a-z0-9][a-z0-9-]{0,30})", self.path)
        if m:
            target = targets().get(m[1])
            if not target or runs_on(target) != me:
                return self.send(403, {"error": "not this machine's target"})
            write(REPORTS / f"dump-{m[1]}.json", data)
            return self.send(200, {"ok": True})
        self.send(404, {"error": "not found"})

    def log_message(self, *args):
        pass


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # The overlay's address may come up after the hub does.
        self.socket.setsockopt(socket.IPPROTO_IP, getattr(socket, "IP_FREEBIND", 15), 1)
        super().server_bind()


if __name__ == "__main__":
    servers = []
    for listen in LISTEN:
        host, port = listen.rsplit(":", 1)
        server = Server((host, int(port)), Hub)
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Event().wait()
