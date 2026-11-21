"""status.bresilla.com: hive and nest, read-only, in two layouts that switch beside the account.

By machine (the default) the top bar is hive and nest, each tab about that one machine.
By function it is Servers and Storage, each tab across both. Hive and nest write their
reports (collect.sh) every five minutes, their sizes and a line of history every hour;
this page only reads them.
"""

import html
import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import site_ui

DATA = Path(os.environ.get("STATUS_DATA", "/var/lib/status"))
LISTEN = os.environ.get("STATUS_LISTEN", "127.0.0.1:8093")
STALE = 15 * 60
HOSTS = ("hive", "nest")
HIVE, NEST, BOTH = ("hive",), ("nest",), HOSTS
RANK = {"ok": 0, "none": 0, "warn": 1, "fail": 2}
BACKUP_JOB = re.compile(r"backup|btrbk|scrub|keep")
COOKIE = "status_view"
e = html.escape

_I = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{}</svg>'
ICON = {k: _I.format(v) for k, v in {
    "overview": '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
    "server": '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    "box": '<path d="M21 8l-9-5-9 5 9 5 9-5z"/><path d="M3 8v8l9 5 9-5V8"/><path d="M12 13v8"/>',
    "clock": '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    "globe": '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    "folder": '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    "history": '<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5M12 7v5l3 2"/>',
    "drive": '<rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 14h.01M11 14h6"/>',
    "cache": '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v6c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/>',
    "snow": '<path d="M12 2v20M4 7l16 10M20 7L4 17"/>',
    "disk": '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="2"/>',
}.items()}

# A tab: (key, label, icon, the view that draws it, the topics its badge counts, the machines it covers).
# A topic is what a problem is about; "*" counts every problem of the tab's machines.
VIEWS = {
    "machine": ("by machine", {
        "hive": ("hive", "server", [
            ("overview", "Overview", "overview", "overview", ("*",), HIVE),
            ("containers", "Containers", "box", "containers", ("containers",), HIVE),
            ("timers", "Timers", "clock", "timers", ("timers", "backups"), HIVE),
            ("sites", "Sites", "globe", "sites", ("sites",), HIVE),
            ("cache", "Cache", "cache", "cache", ("cache",), HIVE),
            ("nix", "Nix", "snow", "nix", ("nix",), HIVE),
            ("disks", "Disks", "disk", "disks", ("disks",), HIVE)]),
        "nest": ("nest", "drive", [
            ("overview", "Overview", "overview", "overview", ("*",), NEST),
            ("shares", "Shares", "folder", "shares", ("shares",), NEST),
            ("backups", "Backups", "history", "backups", ("backups",), NEST),
            ("drive", "Drive", "drive", "drive", ("drive",), NEST),
            ("nix", "Nix", "snow", "nix", ("nix",), NEST),
            ("disks", "Disks", "disk", "disks", ("disks",), NEST)]),
    }),
    "function": ("by function", {
        "servers": ("Servers", "server", [
            ("overview", "Overview", "overview", "overview", ("*",), BOTH),
            ("hive", "hive", "server", "machine", ("host",), HIVE),
            ("nest", "nest", "server", "machine", ("host",), NEST),
            ("containers", "Containers", "box", "containers", ("containers",), HIVE),
            ("timers", "Timers", "clock", "timers", ("timers",), BOTH),
            ("sites", "Sites", "globe", "sites", ("sites",), HIVE)]),
        "storage": ("Storage", "drive", [
            ("shares", "Shares", "folder", "shares", ("shares",), NEST),
            ("backups", "Backups", "history", "backups", ("backups",), BOTH),
            ("drive", "Drive", "drive", "drive", ("drive",), NEST),
            ("cache", "Cache", "cache", "cache", ("cache",), HIVE),
            ("nix", "Nix", "snow", "nix", ("nix",), BOTH),
            ("disks", "Disks", "disk", "disks", ("disks",), BOTH)]),
    }),
}
SECTIONS = {key: (view, *section) for view, (_, sections) in VIEWS.items() for key, section in sections.items()}

STYLE = site_ui.STYLE + """
main { padding-top: 0; }
.band { margin: 0 calc(50% - 50vw) var(--s5); padding: var(--s5) calc(50vw - 50%) 0;
  background: color-mix(in srgb, var(--accent) 6%, var(--page)); border-bottom: 1px solid var(--line); }
.band .head { display: flex; justify-content: space-between; align-items: center; gap: var(--s3); flex-wrap: wrap; }
.band .title { display: flex; align-items: center; gap: var(--s2); font-size: 18px; }
.band .title svg { width: 18px; height: 18px; }
.band .tabs { margin: var(--s4) 0 0; border-bottom: 0; }
.tabs a .count { font-size: var(--site-font-tiny); border-radius: 999px; padding: 0 7px; line-height: 18px; background: var(--line); color: var(--fg); }
.tabs a .count.fail { background: #d64545; color: #fff; } .tabs a .count.warn { background: #d99a1e; color: #fff; }
.switch { display: inline-flex; border: 1px solid var(--line); border-radius: 999px; overflow: hidden; margin-right: var(--s3); }
.switch a { padding: 0 10px; line-height: 24px; font-size: var(--site-font-tiny); color: var(--mute); text-decoration: none; }
.switch a.on { background: color-mix(in srgb, var(--accent) 18%, transparent); color: var(--fg); }
.st { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 8px; background: var(--mute); flex: none; }
.st.ok { background: #2e9e5b; } .st.warn { background: #d99a1e; } .st.fail { background: #d64545; }
.pill.fail { color: #d64545; background: color-mix(in srgb, #d64545 14%, transparent); border-color: color-mix(in srgb, #d64545 35%, transparent); }
.pill.warn { color: #b7800f; background: color-mix(in srgb, #d99a1e 14%, transparent); border-color: color-mix(in srgb, #d99a1e 35%, transparent); }
.pill.ok { color: #2e9e5b; background: color-mix(in srgb, #2e9e5b 14%, transparent); border-color: color-mix(in srgb, #2e9e5b 35%, transparent); }
.bar { width: 110px; height: 6px; border-radius: 3px; background: var(--line); display: inline-block; vertical-align: middle; margin-right: 8px; overflow: hidden; }
.bar i { display: block; height: 100%; background: #2e9e5b; } .bar i.warn { background: #d99a1e; } .bar i.fail { background: #d64545; }
.spark { vertical-align: middle; } .spark polyline { fill: none; stroke: var(--accent); stroke-width: 1.5; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: var(--s4); margin-bottom: var(--s5); }
.tile { border: 1px solid var(--line); border-radius: var(--site-radius-large); padding: var(--s4) var(--s5); background: var(--raised); }
.tile h3 { margin: 0 0 var(--s3); font-size: var(--site-font-size); display: flex; align-items: center; }
.tile dl { margin: 0; display: grid; grid-template-columns: auto 1fr; gap: 4px var(--s4); font-size: var(--site-font-small); }
.tile dt { color: var(--mute); } .tile dd { margin: 0; }
.big { font-size: 22px; } .problems { margin: 0; padding-left: 4px; list-style: none; } .problems li { margin: 6px 0; display: flex; align-items: center; }
.problems a { margin-left: auto; font-size: var(--site-font-small); }
td pre { margin: 0; white-space: pre-wrap; font-size: var(--site-font-tiny); }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
@media (max-width: 720px) { .band .tabs a span.label { display: none; } }
"""
SCRIPT = site_ui.SCRIPT + "setTimeout(() => location.reload(), 60000);"


def load(name):
    try:
        return json.loads((DATA / name).read_text())
    except (OSError, ValueError):
        return None


def history():
    rows = []
    try:
        for line in (DATA / "history.jsonl").read_text().splitlines():
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    except OSError:
        pass
    return rows


def ago(t, now):
    if not t:
        return "never"
    d = int(now - t)
    future, d = d < 0, abs(d)
    for unit, label in ((86400, "d"), (3600, "h"), (60, "min")):
        if d >= unit:
            text = f"{d // unit} {label}"
            break
    else:
        text = f"{d} s"
    return f"in {text}" if future else f"{text} ago"


def stamp(value):
    try:
        return int(str(value).lstrip("@")) or None
    except (TypeError, ValueError):
        return None


def number(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def size(n):
    if n is None:
        return "—"
    n = float(n)
    sign, n = ("-" if n < 0 else ""), abs(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{sign}{n:.0f} {unit}" if unit == "B" else f"{sign}{n:.1f} {unit}"
        n /= 1024


def change(n):
    return "—" if n is None else ("+" if n >= 0 else "") + size(n)


def duration(seconds):
    if not seconds:
        return "—"
    d, s = divmod(int(seconds), 86400)
    h, s = divmod(s, 3600)
    return f"{d} d {h} h" if d else f"{h} h {s // 60} min"


def when(t):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(t)) if t else "—"


def badge(state, text=None):
    return f'<span class="pill {state}">{e(text or state)}</span>'


def dot(state):
    return f'<span class="st {state}"></span>'


def bar(share):
    state = "fail" if share > 0.9 else "warn" if share > 0.8 else "ok"
    return f'<span class=bar><i class={state} style="width:{min(share, 1) * 100:.0f}%"></i></span>{share:.0%}', state


def spark(values, width=110, height=22):
    values = [v for v in values if v is not None]
    if len(values) < 2:
        return '<span class=mute>—</span>'
    low, high = min(values), max(values)
    span = (high - low) or 1
    step = width / (len(values) - 1)
    points = " ".join(f"{i * step:.1f},{height - 2 - (v - low) / span * (height - 4):.1f}" for i, v in enumerate(values))
    return f'<svg class=spark width={width} height={height} viewBox="0 0 {width} {height}"><polyline points="{points}"/></svg>'


def table(head, rows, numeric=()):
    if not rows:
        return '<div class="empty mute">nothing here</div>'
    th = "".join(f'<th class="{"num" if i in numeric else ""}">{e(h)}</th>' for i, h in enumerate(head))
    body = "".join("<tr>" + "".join(f'<td class="{"num" if i in numeric else ""}">{c}</td>' for i, c in enumerate(row)) + "</tr>"
                   for row in rows)
    return f"<table><tr>{th}</tr>{body}</table>"


def section(title, body, state=None, note=""):
    extra = f' <span class=mute style="font-weight:normal">· {e(note)}</span>' if note else ""
    return f'<section class=set><h3>{dot(state) if state else ""}{e(title)}{extra}</h3><div>{body}</div></section>'


def tile(title, rows, state=None):
    items = "".join(f"<dt>{e(k)}</dt><dd>{v}</dd>" for k, v in rows)
    return f'<div class=tile><h3>{dot(state) if state else ""}{e(title)}</h3><dl>{items}</dl></div>'


def on(hosts):
    """A column naming the machine, only where a tab covers both."""
    return len(hosts) > 1


class Report:
    """Both machines' reports. Every check runs once and notes each problem with its
    topic and machine; a tab's badge counts the problems its topics and machines match."""

    def __init__(self):
        self.now = time.time()
        self.problems = []
        self.r = {h: load(f"{h}.json") for h in HOSTS}
        self.sizes = {h: load(f"{h}-sizes.json") for h in HOSTS}
        self.history = history()
        self.check()

    # --- bookkeeping -------------------------------------------------------------------

    def flag(self, state, topic, host, text):
        if state in ("warn", "fail") and text not in [p[3] for p in self.problems]:
            self.problems.append((state, topic, host, text))
        return state

    @staticmethod
    def worst(states):
        return max(states, key=lambda s: RANK[s], default="ok")

    def matching(self, topics, hosts):
        return [p for p in self.problems if p[2] in hosts and ("*" in topics or p[1] in topics)]

    def part(self, host, name, default=None):
        value = (self.r.get(host) or {}).get(name)
        return default if value is None else value

    def series(self, pick, days=7):
        """Values over the last days; a zero is a reading that was missing, not a size."""
        since = self.now - days * 86400
        return [v if v else None for v in (pick(row) for row in self.history if row.get("at", 0) >= since)]

    def growth(self, pick, days=7):
        since = self.now - days * 86400
        points = [(row["at"], pick(row)) for row in self.history if row.get("at", 0) >= since and pick(row)]
        # Under a day of history says nothing about growth yet.
        if len(points) < 2 or points[-1][0] - points[0][0] < 86400:
            return None
        return points[-1][1] - points[0][1]

    def all_timers(self, hosts=BOTH):
        """Each timer as (machine, where it runs, timer); the containers' timers are hive's."""
        out = [(h, h, t) for h in hosts for t in self.part(h, "timers", [])]
        if "hive" in hosts:
            out += [("hive", t.get("machine", "?"), t) for t in self.part("hive", "inner_timers", [])]
        return out

    @staticmethod
    def timer_topic(name):
        return "nix" if name.startswith("nix-gc") else "backups" if BACKUP_JOB.search(name) else "timers"

    # --- every check -------------------------------------------------------------------

    def check(self):
        for host in HOSTS:
            data = self.r[host]
            if data is None:
                self.flag("fail", "host", host, f"{host} has sent no report")
            elif self.now - data.get("at", 0) > STALE:
                self.flag("fail", "host", host, f"{host}'s report is {ago(data.get('at'), self.now)}")
            for u in self.part(host, "failed", []):
                self.flag("fail", "host", host, f"{host}: {u.get('unit')} has failed")
            v = self.part(host, "vitals", {})
            mem = v.get("mem") or {}
            if v.get("temp") and v["temp"] > 85:
                self.flag("warn", "host", host, f"{host}: CPU at {v['temp']:.0f} °C")
            if mem.get("total") and mem.get("available", 0) / mem["total"] < 0.1:
                self.flag("warn", "host", host, f"{host}: under 10% of memory free")
            if v.get("load") and v.get("cpus") and v["load"][1] > v["cpus"] * 2:
                self.flag("warn", "host", host, f"{host}: load {v['load'][1]} on {v['cpus']} CPUs")
        for u in self.part("nest", "units", []):
            if u.get("ActiveState") != "active":
                self.flag("fail", "drive" if "backup" in u.get("Id", "") else "host", "nest",
                          f"nest: {u.get('Id')} is {u.get('ActiveState')}")
        for host, where, t in self.all_timers():
            name = t.get("activates", "").removesuffix(".service").replace("\\x2d", "-")
            service = t.get("service") or {}
            result = service.get("Result", "")
            if (t.get("last") or 0) and (service.get("ActiveState") == "failed" or result not in ("", "success")):
                self.flag("fail", self.timer_topic(name), host, f"{where}: {name} ended with {result or 'failure'}")
        self.check_containers()
        self.check_sites()
        self.check_btrbk()
        self.check_drive()
        self.check_cache()
        self.check_disks()

    def check_containers(self):
        stats = {s["unit"]: s for s in self.part("hive", "container_stats", []) if s.get("unit")}
        for c in self.part("hive", "containers", []):
            name = c.get("unit", "").removeprefix("container@").removesuffix(".service")
            if c.get("active") != "active":
                self.flag("fail", "containers", "hive", f"hive: container {name} is {c.get('active')}")
            elif (number(stats.get(c.get("unit"), {}).get("NRestarts")) or 0) > 3:
                self.flag("warn", "containers", "hive", f"hive: container {name} restarted often")

    def check_sites(self):
        for c in self.part("hive", "certs", []):
            start, until, code = c.get("from"), c.get("until"), c.get("code")
            if code is not None and (not code or code >= 500):
                self.flag("fail", "sites", "hive", f"{c['name']} answers {code or 'nothing'}")
            if not until:
                self.flag("fail", "sites", "hive", f"{c['name']}: no certificate could be read")
            elif until < self.now:
                self.flag("fail", "sites", "hive", f"{c['name']}: certificate expired {ago(until, self.now)}")
            elif start and (until - self.now) < (until - start) / 4:
                self.flag("warn", "sites", "hive", f"{c['name']}: certificate expires {ago(until, self.now)}")

    def newest(self, names, share):
        times = []
        for name in names:
            m = re.fullmatch(re.escape(share) + r"\.(\d{8}T\d{4})(_\d+)?", name)
            if m:
                times.append(time.mktime(time.strptime(m[1], "%Y%m%dT%H%M")))
        return (max(times) if times else None), len(times)

    def btrbk_shares(self):
        """Each share btrbk knows of: (share, state, newest snapshot, count, newest copy, count, retired)."""
        backups = self.part("nest", "backups") or {}
        snaps, copies = backups.get("snapshots", []), backups.get("copies", [])
        taken = backups.get("taken")
        out = []
        for share in sorted({n.split(".")[0] for n in snaps + copies}):
            snap, n_snap = self.newest(snaps, share)
            copy, n_copy = self.newest(copies, share)
            # A share btrbk no longer takes is retired, not failing.
            retired = (share not in taken) if taken else bool(snap and self.now - snap > 2 * 86400)
            out.append((share, snap, n_snap, copy, n_copy, retired))
        return out

    def share_state(self, share, snap, copy):
        s1 = "ok" if snap and self.now - snap < 2 * 3600 else "fail"
        s2 = "warn" if copy is None else "fail" if self.now - copy > 36 * 3600 else "ok"
        return self.worst([s1, s2])

    def check_btrbk(self):
        if not self.part("nest", "backups"):
            self.flag("fail", "backups", "nest", "nest sent no backup listing")
            return
        for share, snap, _, copy, _, retired in self.btrbk_shares():
            if retired:
                continue
            if not (snap and self.now - snap < 2 * 3600):
                self.flag("fail", "backups", "nest", f"{share}: no snapshot in the last 2 h")
            if copy is None:
                self.flag("warn", "backups", "nest", f"{share}: no copy on the backup drive yet")
            elif self.now - copy > 36 * 3600:
                self.flag("fail", "backups", "nest", f"{share}: newest copy on the drive is {ago(copy, self.now)}")

    def drive(self):
        return next((d for d in self.part("nest", "disks", []) if d.get("target") == "/mnt/backup"), None)

    def check_drive(self):
        backups = self.part("nest", "backups") or {}
        if backups and not backups.get("drive"):
            self.flag("fail", "drive", "nest", "the backup drive is not mounted on nest")
        disk = self.drive()
        if disk and disk.get("size"):
            share = disk["used"] / disk["size"]
            self.flag(bar(share)[1], "drive", "nest", f"the backup drive is {share:.0%} full")

    def gc_runs(self):
        runs = []
        for line in (self.part("hive", "cache_stats") or {}).get("gc") or []:
            text = line.get("text", "")
            if text.startswith("Starting"):
                runs.append({"at": line["at"], "deleted": 0, "passes": 0, "result": "running"})
            elif runs and "deleting:" in text:
                runs[-1]["deleted"] += 1
            elif runs and "deleted chunks left" in text:
                runs[-1]["passes"] += 1
            elif runs and text.startswith("Finished"):
                runs[-1]["result"] = "success"
            elif runs and "ailed" in text:
                runs[-1]["result"] = "failed"
        return runs

    def check_cache(self):
        stats = self.part("hive", "cache_stats")
        if not stats:
            self.flag("warn", "cache", "hive", "hive sent no cache numbers")
            return
        runs = self.gc_runs()
        if runs and runs[-1]["result"] == "failed":
            self.flag("fail", "cache", "hive", "the last cache cleanup failed")
        pending = sum(c.get("count", 0) for c in stats.get("chunks") or [] if c.get("state") == "D")
        if pending:
            self.flag("warn", "cache", "hive", f"{pending} cache chunks are waiting to be deleted")

    def check_disks(self):
        for host in HOSTS:
            for d in self.part(host, "disks", []):
                if d.get("target") == "/mnt/backup" or not d.get("size"):
                    continue
                share = d["used"] / d["size"]
                self.flag(bar(share)[1], "disks", host, f"{host}: {d['target']} is {share:.0%} full")
            for md in self.part(host, "raid", []):
                if md.get("degraded", "0") not in ("0", "") or md.get("state") not in ("clean", "active", "active-idle"):
                    self.flag("fail", "disks", host, f"{host}: {md['name']} is {md.get('state')}, degraded {md.get('degraded')}")
            for d in self.part(host, "smart", []):
                if d.get("usb"):
                    continue
                if d.get("passed") is False or (d.get("media_errors") or 0) > 0:
                    self.flag("fail", "disks", host, f"{host}: {d['dev']} ({d.get('model')}) fails its health check")
                elif d.get("passed") is None:
                    self.flag("warn", "disks", host, f"{host}: {d['dev']} gives no health report")
                elif (d.get("temp") or 0) > 70 or (d.get("used") or 0) > 80:
                    self.flag("warn", "disks", host, f"{host}: {d['dev']} is at {d.get('temp')} °C, {d.get('used')}% worn")
            for fs in self.part(host, "btrfs_errors", []):
                topic = "drive" if fs["mount"] == "/mnt/backup" else "disks"
                if not fs.get("mounted"):
                    self.flag("fail", topic, host, f"{host}: {fs['mount']} is not mounted")
                elif fs.get("errors"):
                    self.flag("fail", topic, host, f"{host}: {fs['mount']} has {fs['errors']} btrfs errors")

    # --- the views: each takes the machines its tab covers -------------------------------

    def state_of(self, topics, hosts):
        return self.worst([p[0] for p in self.matching(topics, hosts)] or ["ok"])

    def machine_tile(self, host):
        data = self.r[host]
        if data is None:
            return tile(host, [("report", "none")], "fail")
        v = data.get("vitals") or {}
        mem = v.get("mem") or {}
        used = mem.get("total", 0) - mem.get("available", 0)
        rows = [("report", e(ago(data.get("at"), self.now))), ("up", e(duration(v.get("uptime")))),
                ("load", e(" · ".join(str(x) for x in v.get("load", [])) + (f" on {v['cpus']} CPUs" if v.get("cpus") else ""))),
                ("memory", (bar(used / mem["total"])[0] if mem.get("total") else "—") + f' <span class=mute>{size(used)} of {size(mem.get("total"))}</span>'),
                ("CPU", e(f"{v['temp']:.0f} °C" if v.get("temp") is not None else "—")),
                ("failed units", str(len(data.get("failed") or []))), ("kernel", e(v.get("kernel", "—")))]
        return tile(host, rows, self.state_of(("*",), (host,)))

    def glance(self, host):
        if host == "hive":
            containers = self.part("hive", "containers", [])
            sites = [c for c in self.part("hive", "certs", []) if c.get("code") is not None]
            stored = sum(c.get("size", 0) for c in (self.part("hive", "cache_stats") or {}).get("chunks") or [] if c.get("state") == "V")
            return tile("hive at a glance", [
                ("containers", f'{sum(1 for c in containers if c.get("active") == "active")} of {len(containers)} running'),
                ("sites", f'{sum(1 for c in sites if 200 <= (c.get("code") or 0) < 500)} of {len(sites)} answering'),
                ("timers", f'{len(self.all_timers(HIVE))}, {len(self.matching(("timers", "backups", "nix"), HIVE))} failed'),
                ("cache", e(size(stored))), ("Nix store", e(size((self.part("hive", "nix_store") or {}).get("size"))))])
        du = (self.sizes["nest"] or {}).get("shares_du") or {}
        disk = self.drive()
        shares = self.btrbk_shares()
        snap = max((s[1] for s in shares if s[1] and not s[5]), default=None)
        copy = max((s[3] for s in shares if s[3] and not s[5]), default=None)
        return tile("nest at a glance", [
            ("shares", e(f'{len(du.get("live") or [])}, {size(sum(s.get("total", 0) for s in du.get("live") or []))}')),
            ("newest snapshot", e(ago(snap, self.now))), ("newest drive copy", e(ago(copy, self.now))),
            ("backup drive", bar(disk["used"] / disk["size"])[0] if disk and disk.get("size") else "not mounted"),
            ("Nix store", e(size((self.part("nest", "nix_store") or {}).get("size"))))])

    def overview(self, hosts, view):
        listing = ""
        for s, topic, host, t in sorted(self.matching(("*",), hosts), key=lambda p: -RANK[p[0]]):
            target = self.where(view, topic, host)
            link = f'<a href="{target[0]}">{e(target[1])}</a>' if target else ""
            listing += f"<li>{dot(s)}{e(t)}{link}</li>"
        body = '<div class=grid>' + "".join(self.machine_tile(h) + self.glance(h) for h in hosts) + "</div>"
        body += section("Problems", f"<ul class=problems>{listing}</ul>" if listing else
                        '<div class="empty mute">nothing failed and nothing to look at</div>', self.state_of(("*",), hosts))
        return body

    def machine(self, hosts, view):
        host = hosts[0]
        data = self.r[host] or {}
        failed = [[dot("fail") + e(u.get("unit", "")), e(u.get("description", "")), badge("fail", u.get("sub", "failed"))]
                  for u in data.get("failed") or []]
        body = f'<div class=grid>{self.machine_tile(host)}{self.glance(host)}</div>'
        body += section("Failed units", table(["unit", "what", ""], failed), "fail" if failed else "ok")
        if host == "nest":
            rows = [[dot("ok" if u.get("ActiveState") == "active" else "fail") + e(u.get("Id", "")), e(u.get("Description", "")),
                     badge("ok" if u.get("ActiveState") == "active" else "fail", u.get("SubState") or "?")]
                    for u in data.get("units") or []]
            body += section("Storage services", table(["unit", "what", ""], rows))
        return body

    def containers(self, hosts, view):
        stats = {s["unit"]: s for s in self.part("hive", "container_stats", []) if s.get("unit")}
        disk = {d["name"]: d["size"] for d in (self.sizes["hive"] or {}).get("container_disk") or []}
        rows = []
        for c in self.part("hive", "containers", []):
            unit = c.get("unit", "")
            name = unit.removeprefix("container@").removesuffix(".service")
            s = stats.get(unit, {})
            up = c.get("active") == "active"
            restarts = number(s.get("NRestarts")) or 0
            state = "fail" if not up else "warn" if restarts > 3 else "ok"
            since, cpu = stamp(s.get("ActiveEnterTimestamp")), number(s.get("CPUUsageNSec"))
            rows.append([dot(state) + e(name), badge(state, c.get("sub", "")), e(duration(self.now - since) if since and up else "—"),
                         e(size(number(s.get("MemoryCurrent")))), e(size(number(s.get("MemoryPeak")))),
                         e(duration(cpu / 1e9) if cpu else "—"), e(s.get("TasksCurrent", "—")), str(restarts),
                         e(size(disk.get(name))), spark(self.series(lambda r, n=name: (r.get("containers") or {}).get(n), 30))])
        return section("Containers on hive", table(["container", "state", "up", "memory", "peak", "CPU time", "tasks", "restarts",
                                                    "disk", "disk, 30 days"], rows, numeric=(3, 4, 5, 6, 7, 8)),
                       self.state_of(("containers",), HIVE))

    def timer_table(self, timers):
        rows = []
        for host, where, t in timers:
            name = t.get("activates", "").removesuffix(".service").replace("\\x2d", "-")
            service = t.get("service") or {}
            last, nxt = (t.get("last") or 0) / 1e6, (t.get("next") or 0) / 1e6
            result = service.get("Result", "")
            state = "none" if not last else "fail" if service.get("ActiveState") == "failed" or result not in ("", "success") else "ok"
            # The report is a few minutes old: a run it saw coming may already be due.
            nxt_text = "—" if not nxt else "due" if nxt < self.now else ago(nxt, self.now)
            rows.append((-RANK[state], where, name, [dot(state) + e(name), e(where), e(ago(last, self.now)),
                                                      e(nxt_text), badge(state, (result or "—") if last else "not run")]))
        rows.sort(key=lambda r: r[:3])
        return table(["job", "runs on", "last run", "next run", "result"], [r[3] for r in rows])

    def timers(self, hosts, view):
        note = "hive and the containers on it" if hosts == HIVE else "hive, nest and the containers on hive"
        return section("Timers", self.timer_table(self.all_timers(hosts)), self.state_of(("timers", "backups", "nix"), hosts), note)

    def sites(self, hosts, view):
        rows = []
        for c in self.part("hive", "certs", []):
            start, until, code = c.get("from"), c.get("until"), c.get("code")
            site = code is not None
            bad = (site and (not code or code >= 500)) or not until or until < self.now
            close = until and start and (until - self.now) < (until - start) / 4
            state = "fail" if bad else "warn" if close else "ok"
            issuer = re.sub(r".*CN *= *", "", c.get("issuer") or "") or "—"
            rows.append([dot(state) + e(c["name"]), e(str(code) if site else "—"),
                         e(f"{c['took'] * 1000:.0f} ms" if site and c.get("took") else "—"), e(issuer), e(when(until)),
                         e(ago(until, self.now) if until else "—"), badge(state)])
        return section("Sites and certificates", table(["name", "HTTP", "answer", "issuer", "expires", "left", ""], rows, numeric=(1, 2)),
                       self.state_of(("sites",), HIVE), "as hive sees them")

    def cache(self, hosts, view):
        stats = self.part("hive", "cache_stats")
        state = self.state_of(("cache",), HIVE)
        if not stats:
            return section("Cache", '<div class="empty mute">no numbers from hive yet</div>', state)
        chunks = {c["state"]: c for c in stats.get("chunks") or []}
        per_cache = {}
        for p in self.part("hive", "pins", []):
            for c in p.get("caches") or []:
                per_cache[c] = per_cache.get(c, 0) + 1
        week, nars, runs = stats.get("week") or {}, stats.get("nars") or {}, self.gc_runs()
        stored = (chunks.get("V") or {}).get("size", 0)
        body = '<div class=grid>' + tile("Stored", [
            ("on disk", f'<span class=big>{e(size(stored))}</span>'), ("chunks", e(f'{(chunks.get("V") or {}).get("count", 0):,}')),
            ("packages", e(f'{nars.get("count", 0):,} · {size(nars.get("size"))} unpacked')),
            ("30 days", spark(self.series(lambda r: r.get("chunks"), 30), 160, 26))]) + tile("This week", [
            ("pushed", e(f'{week.get("objects", 0):,} paths')), ("their size", e(size(week.get("size")))),
            ("growth", e(change(self.growth(lambda r: r.get("chunks")))))]) + tile("Cleanup", [
            ("waiting to delete", e(f'{(chunks.get("D") or {}).get("count", 0):,} chunks')),
            ("unused packages", e(f'{nars.get("unheld") or 0:,}')),
            ("last run", e(ago(runs[-1]["at"], self.now) if runs else "none in 30 days"))], state) + "</div>"
        rows = [[e(c["name"]), e(f'{c.get("objects", 0):,}'), e(size(c.get("size"))), str(per_cache.get(c["name"], 0)),
                 e((c.get("newest") or "—")[:16].replace("T", " ")),
                 spark(self.series(lambda r, n=c["name"]: (r.get("cache") or {}).get(n), 30))] for c in stats.get("caches") or []]
        body += section("Caches", table(["cache", "paths", "size", "pins", "newest push", "30 days"], rows, numeric=(1, 2, 3)))
        done = [[e(when(r["at"])), str(r["deleted"]), str(r["passes"]),
                 badge("ok" if r["result"] == "success" else "fail" if r["result"] == "failed" else "none", r["result"])]
                for r in reversed(runs[-15:])]
        body += section("Cleanup runs (attic-gc)", table(["started", "unpinned paths dropped", "passes", "result"], done, numeric=(1, 2)),
                        state, "nightly, keeps every pinned build and its closure")
        return body

    def nix(self, hosts, view):
        tiles, logs = "", []
        for host in hosts:
            store = self.part(host, "nix_store") or {}
            # The filesystem the store lives on: the longest mount that holds /nix/store.
            holding = [d for d in self.part(host, "disks", []) if d["target"] == "/" or "/nix/store".startswith(d["target"] + "/")]
            fs = max(holding, key=lambda d: len(d["target"]), default=None)
            gc = next((t for h, w, t in self.all_timers((host,)) if w == host and t.get("activates") == "nix-gc.service"), {})
            tiles += tile(host, [("store", f'<span class=big>{e(size(store.get("size")))}</span>'),
                                 ("paths", e(f'{store.get("paths", 0):,}')),
                                 ("its disk", bar(fs["used"] / fs["size"])[0] + f' <span class=mute>{e(fs["target"])}</span>' if fs else "—"),
                                 ("7 days", e(change(self.growth(lambda r, h=host: (r.get("nix") or {}).get(h))))),
                                 ("30 days", spark(self.series(lambda r, h=host: (r.get("nix") or {}).get(h), 30), 160, 26)),
                                 ("nix-gc", e(f'last {ago((gc.get("last") or 0) / 1e6, self.now)}, next {ago((gc.get("next") or 0) / 1e6, self.now)}'
                                              if gc else "no timer"))], self.state_of(("nix",), (host,)))
            for line in reversed(store.get("gc") or []):
                logs.append([e(host)] * on(hosts) + [e(when(line["at"])), e(line["text"])])
        head = ["on"] * on(hosts) + ["when", ""]
        return f'<div class=grid>{tiles}</div>' + section("What nix-gc freed", table(head, logs[:30]),
                                                           self.state_of(("nix",), hosts), "last 60 days")

    def disks(self, hosts, view):
        many = on(hosts)
        fs_rows, raid_rows, smart_rows, btrfs_rows = [], [], [], []
        for host in hosts:
            col = [e(host)] * many
            for d in self.part(host, "disks", []):
                cell, state = bar(d["used"] / d["size"]) if d.get("size") else ("—", "none")
                key = f"{host}:{d['target']}"
                fs_rows.append([dot(state) + e(d["target"])] + col + [e(d["source"]), cell, e(size(d["used"])), e(size(d["avail"])),
                                                                     spark(self.series(lambda r, k=key: (r.get("disks") or {}).get(k), 30))])
            for md in self.part(host, "raid", []):
                bad = md.get("degraded", "0") not in ("0", "") or md.get("state") not in ("clean", "active", "active-idle")
                state = "fail" if bad else "ok"
                raid_rows.append([dot(state) + e(md["name"])] + col + [e(md.get("level", "")), e(md.get("state", "")),
                                                                       e(md.get("degraded", "")), e(md.get("sync", "")), badge(state)])
            for d in self.part(host, "smart", []):
                if d.get("usb"):
                    smart_rows.append([dot("none") + e(d["dev"])] + col + [e(d.get("model") or ""), "—", "—", "—", "—",
                                                                           badge("none", "not available over USB")])
                    continue
                passed, temp, used = d.get("passed"), d.get("temp"), d.get("used")
                state = ("fail" if passed is False or (d.get("media_errors") or 0) > 0 else "warn" if passed is None
                         or (temp or 0) > 70 or (used or 0) > 80 else "ok")
                smart_rows.append([dot(state) + e(d["dev"])] + col + [
                    e(d.get("model") or ""), e(f"{temp} °C" if temp is not None else "—"), e(f"{used}%" if used is not None else "—"),
                    e(f"{d['hours']} h" if d.get("hours") is not None else "—"),
                    e(str(d.get("media_errors")) if d.get("media_errors") is not None else "—"),
                    badge(state, "passed" if passed else "failed" if passed is False else "unknown")])
            scrubs = {s["mount"]: s.get("text", "") for s in self.part(host, "scrub", [])}
            for fs in self.part(host, "btrfs_errors", []):
                state = "fail" if not fs.get("mounted") or fs.get("errors") else "ok"
                summary = "\n".join(l.strip() for l in scrubs.get(fs["mount"], "").splitlines()
                                    if re.match(r"\s*(Status|Scrub started|Error summary)", l))
                btrfs_rows.append([dot(state) + e(fs["mount"])] + col + [e(str(fs.get("errors", "—"))), f"<pre>{e(summary) or '—'}</pre>",
                                                                         badge(state)])
        h = ["on"] * many
        state = self.state_of(("disks",), hosts)
        body = section("Filesystems", table(["mount"] + h + ["device", "used", "used", "free", "30 days"], fs_rows,
                                            numeric=(3 + many, 4 + many)), state)
        body += section("RAID", table(["array"] + h + ["level", "state", "degraded", "sync", ""], raid_rows))
        body += section("Drives", table(["drive"] + h + ["model", "temperature", "worn", "powered on", "media errors", "health"], smart_rows))
        body += section("btrfs errors and checks", table(["filesystem"] + h + ["errors", "last check", ""], btrfs_rows))
        return body

    def shares(self, hosts, view):
        du = (self.sizes["nest"] or {}).get("shares_du") or {}
        snaps = {s["share"]: s for s in du.get("snapshots") or []}
        drive = {s["share"]: s for s in du.get("drive") or []}
        taken = {s[0] for s in self.btrbk_shares() if not s[5]}
        rows = []
        for s in sorted(du.get("live") or [], key=lambda s: -s.get("total", 0)):
            n = s["share"]
            sn, dr = snaps.get(n, {}), drive.get(n, {})
            kept = badge("ok", "backed up") if n in taken else badge("none", "not backed up" if n == "@cache-chunks" else "retired")
            rows.append([e(n), e(size(s.get("total"))), e(size(s.get("exclusive"))), e(str(sn.get("count", 0))),
                         e(size(sn.get("exclusive")) if sn else "—"), e(size(dr.get("newest")) if dr else "—"),
                         e(change(self.growth(lambda r, n=n: (r.get("shares") or {}).get(n)))),
                         spark(self.series(lambda r, n=n: (r.get("shares") or {}).get(n))), kept])
        measured = (self.sizes["nest"] or {}).get("at")
        return section("Shares on nest", table(["share", "size", "its own", "snapshots", "held by snapshots", "newest on drive",
                                                "7 days", "7 days", ""], rows, numeric=(1, 2, 3, 4, 5, 6)), None,
                       f"measured {ago(measured, self.now)}" if measured else "not measured yet")

    def backups(self, hosts, view):
        body = ""
        if "nest" in hosts:
            rows, restore = [], []
            for share, snap, n_snap, copy, n_copy, retired in self.btrbk_shares():
                state = "none" if retired else self.share_state(share, snap, copy)
                rows.append([dot(state) + e(share), e(ago(snap, self.now)), str(n_snap), e(ago(copy, self.now)), str(n_copy),
                             badge(state, "retired" if retired else None)])
                if copy and not retired:
                    restore.append([e(share), e(when(copy)), e(ago(copy, self.now))])
            body += section("btrbk: snapshots on nest and copies on the drive",
                            table(["share", "newest snapshot", "snapshots", "newest on drive", "on drive", ""], rows, numeric=(2, 4)),
                            self.worst([p[0] for p in self.matching(("backups",), NEST) if "snapshot" in p[3] or "drive" in p[3]] or ["ok"]))
        jobs = [t for t in self.all_timers(hosts) if BACKUP_JOB.search(t[2].get("activates", ""))]
        body += section("Backup jobs", self.timer_table(jobs), self.state_of(("backups",), hosts),
                        "nest's own" if hosts == NEST else "every machine and container")
        if "nest" in hosts:
            body += section("Restore points on the drive", table(["share", "newest copy", ""], restore))
        return body

    def drive_tab(self, hosts, view):
        nest = self.r["nest"] or {}
        disk = self.drive()
        state = self.state_of(("drive",), NEST)
        du = (self.sizes["nest"] or {}).get("shares_du") or {}
        rows = []
        if disk and disk.get("size"):
            grow = self.growth(lambda r: (r.get("disks") or {}).get("nest:/mnt/backup"), 30)
            rows = [["used", bar(disk["used"] / disk["size"])[0] + f' {size(disk["used"])} of {size(disk["size"])}'],
                    ["free", e(size(disk["avail"]))], ["30 days", e(change(grow))],
                    ["history", spark(self.series(lambda r: (r.get("disks") or {}).get("nest:/mnt/backup"), 30), 200, 28)]]
            if grow and grow > 0:
                days = disk["avail"] / (grow / 30)
                rows.append(["full in", e(f"about {days / 30:.0f} months" if days > 60 else f"about {days:.0f} days")])
        body = section("The backup drive", table(["", ""], rows) if rows else '<div class="empty mute">not mounted</div>', state,
                       "/mnt/backup on nest, LUKS and btrfs")
        copies = [[e(d["share"]), str(d.get("count", 0)), e(size(d.get("newest"))), e(size(d.get("exclusive")))]
                  for d in du.get("drive") or []]
        body += section("Copies per share", table(["share", "copies", "newest copy", "held by older copies"], copies, numeric=(1, 2, 3)))
        units = [[e(u.get("Id", "")), badge("ok" if u.get("ActiveState") == "active" else "fail", u.get("SubState") or "?")]
                 for u in nest.get("units") or [] if "backup" in u.get("Id", "")]
        errors = next((f.get("errors") for f in nest.get("btrfs_errors") or [] if f.get("mount") == "/mnt/backup"), None)
        scrub = next((s.get("text", "") for s in nest.get("scrub") or [] if s.get("mount") == "/mnt/backup"), "")
        summary = "\n".join(l.strip() for l in scrub.splitlines() if re.match(r"\s*(Status|Scrub started|Error summary)", l))
        body += section("Health", table(["", ""], [["btrfs errors", e(str(errors) if errors is not None else "—")],
                                                   ["last check", f"<pre>{e(summary) or '—'}</pre>"],
                                                   ["drive health", badge("none", "not available over USB")]] + units))
        return body

    # --- the frame ----------------------------------------------------------------------

    def where(self, view, topic, host):
        """The tab in this layout a problem belongs to: (href, label), or None."""
        for key, (title, _, tabs) in VIEWS[view][1].items():
            for tab, label, _, _, topics, hosts in tabs:
                if topic in topics and host in hosts:
                    return f"/{key}/{tab}", f"{title} · {label}"
        return None

    def band(self, key, active):
        view, title, icon, tabs = SECTIONS[key]
        links, seen = "", set()
        for tab, label, tab_icon, _, topics, hosts in tabs:
            found = self.matching(topics, hosts)
            seen.update(p[3] for p in found)
            fails, warns = sum(1 for p in found if p[0] == "fail"), sum(1 for p in found if p[0] == "warn")
            count = f'<span class="count fail">{fails}</span>' if fails else f'<span class="count warn">{warns}</span>' if warns else ""
            links += f'<a href="/{key}/{tab}" class="{"on" if tab == active else ""}">{ICON[tab_icon]}<span class=label>{e(label)}</span>{count}</a>'
        mine = [p for p in self.problems if p[3] in seen]
        fails, warns = sum(1 for p in mine if p[0] == "fail"), sum(1 for p in mine if p[0] == "warn")
        covered = sorted({h for t in tabs for h in t[5]}, key=HOSTS.index)
        ages = " · ".join(f"{h} {ago((self.r[h] or {}).get('at'), self.now)}" for h in covered)
        head = (f'<div class=head><div class=title>{ICON[icon]}{e(title)}</div><div class=summary>'
                f'{badge("fail" if fails else "ok", f"{fails} failed")}{badge("warn" if warns else "ok", f"{warns} to look at")}'
                f'<span class=mute>reported {e(ages)}</span></div></div>')
        return f'<div class=band>{head}<div class=tabs>{links}</div></div>'

    def render(self, key, tab):
        view, _, _, tabs = SECTIONS[key]
        _, _, _, draw, _, hosts = next(t for t in tabs if t[0] == tab)
        method = {"drive": self.drive_tab}.get(draw) or getattr(self, draw)
        return self.band(key, tab) + method(hosts, view)


def first(view):
    key, (_, _, tabs) = next(iter(VIEWS[view][1].items()))
    return f"/{key}/{tabs[0][0]}"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        # Caddy strips these from visitors; only the login proxy sets them.
        name = self.headers.get("X-Forwarded-Preferred-Username") or self.headers.get("X-Forwarded-User")
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        cookie = re.search(COOKIE + r"=(\w+)", self.headers.get("Cookie", ""))
        chosen = cookie[1] if cookie and cookie[1] in VIEWS else "machine"
        if not name:
            return self.reply(403, "sign in", '<div class="card empty">sign in on id.bresilla.com first</div>', name, chosen, None)
        if parts[:2] and parts[0] == "-" and len(parts) == 3 and parts[1] == "view" and parts[2] in VIEWS:
            return self.redirect(first(parts[2]), f"{COOKIE}={parts[2]}; Path=/; Max-Age=31536000; Secure; SameSite=Lax")
        if not parts:
            return self.redirect(first(chosen))
        key = parts[0]
        if key not in SECTIONS or len(parts) > 2:
            return self.reply(404, "not found", '<div class="card empty">not found</div>', name, chosen, None)
        view, title, _, tabs = SECTIONS[key]
        if len(parts) == 1:
            return self.redirect(f"/{key}/{tabs[0][0]}")
        labels = {t[0]: t[1] for t in tabs}
        if parts[1] not in labels:
            return self.reply(404, "not found", '<div class="card empty">not found</div>', name, view, key)
        self.reply(200, f"{labels[parts[1]]} · {title}", Report().render(key, parts[1]), name, view, key)

    def redirect(self, to, cookie=None):
        self.send_response(302)
        self.send_header("Location", to)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def reply(self, code, title, body, name, view, active):
        links = [(k, f"/{k}", s[0]) for k, s in VIEWS[view][1].items()]
        switch = "".join(f'<a href="/-/view/{v}" class="{"on" if v == view else ""}">{e(label)}</a>' for v, (label, _) in VIEWS.items())
        page = site_ui.page(site="status", title=title, body=body, links=links, active=active, name=name, here=self.path,
                            style=STYLE, script=SCRIPT, account_extra=f'<span class=switch>{switch}</span>' if name else "").encode()
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
