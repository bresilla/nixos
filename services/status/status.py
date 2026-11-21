"""status.bresilla.com: what failed and what is fine on hive and nest, read-only.

Hive and nest each write a report (collect.sh) every few minutes; this page only
reads those two files, so it never touches either machine.
"""

import html
import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import site_ui

DATA = Path(os.environ.get("STATUS_DATA", "/var/lib/status"))
LISTEN = os.environ.get("STATUS_LISTEN", "127.0.0.1:8093")
STALE = 15 * 60
e = html.escape
RANK = {"ok": 0, "none": 0, "warn": 1, "fail": 2}

STYLE = site_ui.STYLE + """
.st { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 8px; background: var(--mute); }
.st.ok { background: #2e9e5b; } .st.warn { background: #d99a1e; } .st.fail { background: #d64545; }
.pill.fail { color: #d64545; background: color-mix(in srgb, #d64545 14%, transparent); border-color: color-mix(in srgb, #d64545 35%, transparent); }
.pill.warn { color: #b7800f; background: color-mix(in srgb, #d99a1e 14%, transparent); border-color: color-mix(in srgb, #d99a1e 35%, transparent); }
.pill.ok { color: #2e9e5b; background: color-mix(in srgb, #2e9e5b 14%, transparent); border-color: color-mix(in srgb, #2e9e5b 35%, transparent); }
.bar { width: 120px; height: 6px; border-radius: 3px; background: var(--line); display: inline-block; vertical-align: middle; margin-right: 8px; overflow: hidden; }
.bar i { display: block; height: 100%; background: #2e9e5b; } .bar i.warn { background: #d99a1e; } .bar i.fail { background: #d64545; }
.problems li { margin: 4px 0; } .problems { margin: 0; padding-left: 20px; }
td pre { margin: 0; white-space: pre-wrap; font-size: var(--site-font-tiny); }
"""
SCRIPT = site_ui.SCRIPT + "setTimeout(() => location.reload(), 60000);"


def load(host):
    try:
        return json.loads((DATA / f"{host}.json").read_text())
    except (OSError, ValueError):
        return None


def ago(t, now):
    if not t:
        return "never"
    d = int(now - t)
    future = d < 0
    d = abs(d)
    for size, unit in ((86400, "d"), (3600, "h"), (60, "min")):
        if d >= size:
            text = f"{d // size} {unit}"
            break
    else:
        text = f"{d} s"
    return f"in {text}" if future else f"{text} ago"


def stamp(value):
    """systemd's '@<seconds>' timestamps, or none."""
    try:
        return int(str(value).lstrip("@")) or None
    except ValueError:
        return None


def size(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def badge(state, text=None):
    return f'<span class="pill {state}">{e(text or state)}</span>'


def dot(state):
    return f'<span class="st {state}"></span>'


def table(head, rows):
    if not rows:
        return '<div class="empty mute">nothing here</div>'
    th = "".join(f"<th>{e(h)}</th>" for h in head)
    body = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in row) + "</tr>" for row in rows)
    return f"<table><tr>{th}</tr>{body}</table>"


def section(title, body, state=None):
    mark = dot(state) if state else ""
    return f'<section class=set><h3>{mark}{e(title)}</h3><div>{body}</div></section>'


class Report:
    """Turns the two machines' reports into rows, noting every problem on the way."""

    def __init__(self):
        self.now = time.time()
        self.problems = []
        self.hosts = {h: load(h) for h in ("hive", "nest")}

    def flag(self, state, text):
        if state in ("warn", "fail"):
            self.problems.append((state, text))
        return state

    def worst(self, states):
        return max(states, key=lambda s: RANK[s], default="ok")

    def freshness(self):
        rows, states = [], []
        for host, data in self.hosts.items():
            if data is None:
                state = self.flag("fail", f"{host} has sent no report")
                rows.append([dot(state) + e(host), "no report", badge(state)])
            else:
                old = self.now - data.get("at", 0)
                state = self.flag("fail" if old > STALE else "ok", f"{host}'s report is {ago(data.get('at'), self.now)}")
                rows.append([dot(state) + e(host), e(ago(data.get("at"), self.now)), badge(state)])
            states.append(state)
        return rows, self.worst(states)

    def run_state(self, service, host):
        result = service.get("Result", "")
        if service.get("ActiveState") == "failed" or result not in ("", "success"):
            return self.flag("fail", f"{host}: {service.get('Id')} ended with {result or 'failure'}")
        return "ok"

    def timer_rows(self, host, only=None):
        rows, states = [], []
        for t in (self.hosts[host] or {}).get("timers") or []:
            name = t.get("activates", "")
            if only and not only.search(name):
                continue
            service = t.get("service") or {}
            last = (t.get("last") or 0) / 1e6
            state = self.run_state(service, host) if last else "none"
            states.append(state)
            nxt = (t.get("next") or 0) / 1e6
            rows.append([dot(state) + e(name.removesuffix(".service")), e(host), e(ago(last, self.now)),
                         e(ago(nxt, self.now) if nxt else "—"), badge(state, service.get("Result") or "not run")])
        return rows, self.worst(states)

    def failed_rows(self, host):
        rows = []
        for u in (self.hosts[host] or {}).get("failed") or []:
            self.flag("fail", f"{host}: {u.get('unit')} has failed")
            rows.append([dot("fail") + e(u.get("unit", "")), e(u.get("description", "")), badge("fail", u.get("sub", "failed"))])
        return rows

    # btrbk names each snapshot <share>.<YYYYMMDDTHHMM>, in nest's local time.
    def newest(self, names, share):
        times = []
        for name in names:
            m = re.fullmatch(re.escape(share) + r"\.(\d{8}T\d{4})(_\d+)?", name)
            if m:
                times.append(time.mktime(time.strptime(m[1], "%Y%m%dT%H%M")))
        return (max(times) if times else None), len(times)

    def btrbk_rows(self):
        backups = (self.hosts["nest"] or {}).get("backups")
        if not backups:
            return [], self.flag("fail", "nest sent no backup listing")
        rows, states = [], []
        if not backups.get("drive"):
            states.append(self.flag("fail", "the backup drive is not mounted on nest"))
        shares = sorted({n.split(".")[0] for n in backups.get("snapshots", []) + backups.get("copies", [])})
        for share in shares:
            snap, snaps = self.newest(backups.get("snapshots", []), share)
            copy, copies = self.newest(backups.get("copies", []), share)
            s1 = "ok" if snap and self.now - snap < 2 * 3600 else self.flag("fail", f"{share}: no snapshot in the last 2 h")
            if copy is None:
                s2 = self.flag("warn", f"{share}: no copy on the backup drive yet")
            elif self.now - copy > 36 * 3600:
                s2 = self.flag("fail", f"{share}: newest copy on the drive is {ago(copy, self.now)}")
            else:
                s2 = "ok"
            state = self.worst([s1, s2])
            states.append(state)
            rows.append([dot(state) + e(share), e(ago(snap, self.now)), str(snaps), e(ago(copy, self.now)), str(copies), badge(state)])
        return rows, self.worst(states)

    def disk_rows(self):
        rows, states = [], []
        for d in (self.hosts["nest"] or {}).get("disks") or []:
            share = d["used"] / d["size"] if d.get("size") else 0
            state = "fail" if share > 0.9 else "warn" if share > 0.8 else "ok"
            self.flag(state, f"nest: {d['target']} is {share:.0%} full")
            states.append(state)
            bar = f'<span class=bar><i class={state} style="width:{share * 100:.0f}%"></i></span>{share:.0%}'
            rows.append([dot(state) + e(d["target"]), e(d["source"]), bar, e(size(d["used"])), e(size(d["avail"]))])
        return rows, self.worst(states)

    def raid_rows(self):
        rows, states = [], []
        for md in (self.hosts["nest"] or {}).get("raid") or []:
            bad = md.get("degraded", "0") not in ("0", "") or md.get("state") not in ("clean", "active", "active-idle")
            state = self.flag("fail" if bad else "ok", f"nest: {md['name']} is {md.get('state')}, degraded {md.get('degraded')}")
            states.append(state)
            rows.append([dot(state) + e(md["name"]), e(md.get("level", "")), e(md.get("state", "")),
                         e(md.get("degraded", "")), e(md.get("sync", "")), badge(state)])
        return rows, self.worst(states)

    def smart_rows(self):
        rows, states = [], []
        for d in (self.hosts["nest"] or {}).get("smart") or []:
            passed, temp, used = d.get("passed"), d.get("temp"), d.get("used")
            if d.get("usb"):
                rows.append([dot("none") + e(d["dev"]), e(d.get("model") or ""), "—", "—", "—", "—",
                             badge("none", "not available over USB")])
                continue
            if passed is False or (d.get("media_errors") or 0) > 0:
                state = self.flag("fail", f"nest: {d['dev']} ({d.get('model')}) fails its health check")
            elif passed is None:
                state = self.flag("warn", f"nest: {d['dev']} gives no health report")
            elif (temp or 0) > 70 or (used or 0) > 80:
                state = self.flag("warn", f"nest: {d['dev']} is at {temp} °C, {used}% worn")
            else:
                state = "ok"
            states.append(state)
            rows.append([dot(state) + e(d["dev"]), e(d.get("model") or ""), e(f"{temp} °C" if temp is not None else "—"),
                         e(f"{used}%" if used is not None else "—"), e(str(d.get("media_errors") if d.get("media_errors") is not None else "—")),
                         e(f"{d['hours']} h" if d.get("hours") is not None else "—"), badge(state, "passed" if passed else "failed" if passed is False else "unknown")])
        return rows, self.worst(states)

    def btrfs_rows(self):
        rows, states = [], []
        nest = self.hosts["nest"] or {}
        scrubs = {s["mount"]: s.get("text", "") for s in nest.get("scrub") or []}
        for fs in nest.get("btrfs_errors") or []:
            if not fs.get("mounted"):
                state = self.flag("fail", f"nest: {fs['mount']} is not mounted")
            else:
                state = self.flag("fail" if fs.get("errors") else "ok", f"nest: {fs['mount']} has {fs.get('errors')} btrfs errors")
            states.append(state)
            scrub = scrubs.get(fs["mount"], "")
            summary = "\n".join(line.strip() for line in scrub.splitlines() if re.match(r"\s*(Status|Scrub started|Error summary)", line))
            rows.append([dot(state) + e(fs["mount"]), e(str(fs.get("errors", "—"))), f"<pre>{e(summary) or '—'}</pre>", badge(state)])
        return rows, self.worst(states)

    def unit_rows(self, host):
        rows, states = [], []
        for u in (self.hosts[host] or {}).get("units") or []:
            up = u.get("ActiveState") == "active"
            state = self.flag("ok" if up else "fail", f"{host}: {u.get('Id')} is {u.get('ActiveState')}")
            states.append(state)
            rows.append([dot(state) + e(u.get("Id", "")), e(u.get("Description", "")), badge(state, u.get("SubState") or "?")])
        return rows, self.worst(states)

    def container_rows(self):
        rows, states = [], []
        for c in (self.hosts["hive"] or {}).get("containers") or []:
            name = c.get("unit", "").removeprefix("container@").removesuffix(".service")
            up = c.get("active") == "active"
            state = self.flag("ok" if up else "fail", f"hive: container {name} is {c.get('active')}")
            states.append(state)
            rows.append([dot(state) + e(name), e(c.get("sub", "")), badge(state, c.get("active"))])
        return rows, self.worst(states)

    def cert_rows(self):
        rows, states = [], []
        for c in (self.hosts["hive"] or {}).get("certs") or []:
            start, until = c.get("from"), c.get("until")
            if not until:
                state = self.flag("fail", f"{c['name']}: no certificate could be read")
            elif until < self.now:
                state = self.flag("fail", f"{c['name']}: certificate expired {ago(until, self.now)}")
            elif start and (until - self.now) < (until - start) / 4:
                state = self.flag("warn", f"{c['name']}: certificate expires {ago(until, self.now)}")
            else:
                state = "ok"
            states.append(state)
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(until)) if until else "—"
            issuer = re.sub(r".*CN *= *", "", c.get("issuer") or "") or "—"
            rows.append([dot(state) + e(c["name"]), e(issuer), e(when), e(ago(until, self.now) if until else "—"), badge(state)])
        return rows, self.worst(states)

    def render(self):
        fresh, fresh_state = self.freshness()
        backup_units = re.compile(r"backup|btrbk|scrub|keep")
        btrbk, btrbk_state = self.btrbk_rows()
        hive_jobs, hive_jobs_state = self.timer_rows("hive", backup_units)
        nest_jobs, nest_jobs_state = self.timer_rows("nest", backup_units)
        hive_failed, nest_failed = self.failed_rows("hive"), self.failed_rows("nest")
        containers, containers_state = self.container_rows()
        timers, timers_state = self.timer_rows("hive")
        nest_units, nest_units_state = self.unit_rows("nest")
        disks, disks_state = self.disk_rows()
        raid, raid_state = self.raid_rows()
        smart, smart_state = self.smart_rows()
        btrfs, btrfs_state = self.btrfs_rows()
        certs, certs_state = self.cert_rows()

        fails = [t for s, t in self.problems if s == "fail"]
        warns = [t for s, t in self.problems if s == "warn"]
        overall = "fail" if fails else "warn" if warns else "ok"
        listing = "".join(f"<li>{dot(s)}{e(t)}</li>" for s, t in sorted(self.problems, key=lambda p: -RANK[p[0]]))
        head = (f'<h1>{dot(overall)}{"Everything is fine" if overall == "ok" else f"{len(fails)} failed, {len(warns)} to look at"}</h1>'
                f'<div class=stats><div><b>{len(fails)}</b>failed</div><div><b>{len(warns)}</b>warnings</div></div>')
        body = head
        if listing:
            body += section("Problems", f"<ul class=problems>{listing}</ul>", overall)
        body += section("Reports", table(["machine", "sent", ""], fresh), fresh_state)
        body += "<h2>Backups</h2>"
        body += section("btrbk on nest: snapshots and the backup drive",
                        table(["share", "newest snapshot", "snapshots", "newest on drive", "on drive", ""], btrbk), btrbk_state)
        body += section("Backup jobs", table(["job", "on", "last run", "next run", "result"], hive_jobs + nest_jobs),
                        self.worst([hive_jobs_state, nest_jobs_state]))
        body += "<h2>Hive</h2>"
        body += section("Failed units", table(["unit", "what", ""], hive_failed), "fail" if hive_failed else "ok")
        body += section("Containers", table(["container", "state", ""], containers), containers_state)
        body += section("Timers", table(["job", "on", "last run", "next run", "result"], timers), timers_state)
        body += "<h2>Nest</h2>"
        body += section("Failed units", table(["unit", "what", ""], nest_failed), "fail" if nest_failed else "ok")
        body += section("Storage services", table(["unit", "what", ""], nest_units), nest_units_state)
        body += section("Filesystems", table(["mount", "device", "used", "used", "free"], disks), disks_state)
        body += section("RAID", table(["array", "level", "state", "degraded", "sync", ""], raid), raid_state)
        body += section("Drives", table(["drive", "model", "temperature", "worn", "media errors", "powered on", "health"], smart), smart_state)
        body += section("btrfs errors and scrubs", table(["filesystem", "errors", "last scrub", ""], btrfs), btrfs_state)
        body += "<h2>Certificates</h2>"
        body += section("Certificates", table(["name", "issuer", "expires", "left", ""], certs), certs_state)
        return body


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        # Caddy strips these from visitors; only the login proxy sets them.
        name = self.headers.get("X-Forwarded-Preferred-Username") or self.headers.get("X-Forwarded-User")
        if self.path.split("?")[0] != "/":
            return self.reply(404, "not found", '<div class="card empty">not found</div>', name)
        if not name:
            return self.reply(403, "sign in", '<div class="card empty">sign in on id.bresilla.com first</div>', name)
        self.reply(200, "status", Report().render(), name)

    def reply(self, code, title, body, name):
        page = site_ui.page(site="status", title=title, body=body, links=[("status", "/", "overview")],
                            active="status", name=name, style=STYLE, script=SCRIPT).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    host, port = LISTEN.rsplit(":", 1)
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()
