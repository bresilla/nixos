"""status.bresilla.com: hive and nest, read-only, in two sections with tabs of their own.

Hive and nest each write reports (collect.sh): every five minutes their state, every
hour their sizes; hive adds a line of history each hour. This page only reads them.
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
RANK = {"ok": 0, "none": 0, "warn": 1, "fail": 2}
BACKUP_JOB = re.compile(r"backup|btrbk|scrub|keep")
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

SECTIONS = {
    "servers": ("Servers", "server", [
        ("overview", "Overview", "overview"), ("hive", "hive", "server"), ("nest", "nest", "server"),
        ("containers", "Containers", "box"), ("timers", "Timers", "clock"), ("sites", "Sites", "globe")]),
    "storage": ("Storage", "drive", [
        ("shares", "Shares", "folder"), ("backups", "Backups", "history"), ("drive", "Drive", "drive"),
        ("cache", "Cache", "cache"), ("nix", "Nix", "snow"), ("disks", "Disks", "disk")]),
}

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
.right { text-align: right; } td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
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
    sign = "-" if n < 0 else ""
    n = abs(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{sign}{n:.0f} {unit}" if unit == "B" else f"{sign}{n:.1f} {unit}"
        n /= 1024


def duration(seconds):
    if not seconds:
        return "—"
    s = int(seconds)
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    return f"{d} d {h} h" if d else f"{h} h {s // 60} min"


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
    mark = dot(state) if state else ""
    extra = f' <span class=mute style="font-weight:normal">· {e(note)}</span>' if note else ""
    return f'<section class=set><h3>{mark}{e(title)}{extra}</h3><div>{body}</div></section>'


def tile(title, rows, state=None):
    items = "".join(f"<dt>{e(k)}</dt><dd>{v}</dd>" for k, v in rows)
    return f'<div class=tile><h3>{dot(state) if state else ""}{e(title)}</h3><dl>{items}</dl></div>'


class Report:
    """Both machines' reports, with every problem noted against the tab it belongs to."""

    def __init__(self):
        self.now = time.time()
        self.problems = []
        self.r = {h: load(f"{h}.json") for h in HOSTS}
        self.sizes = {h: load(f"{h}-sizes.json") for h in HOSTS}
        self.history = history()

    # --- bookkeeping ---------------------------------------------------------------------

    def flag(self, state, tab, text):
        if state in ("warn", "fail") and (state, text) not in [(s, t) for s, _, t in self.problems]:
            self.problems.append((state, tab, text))
        return state

    @staticmethod
    def worst(states):
        return max(states, key=lambda s: RANK[s], default="ok")

    def count(self, tab, state=None):
        return sum(1 for s, t, _ in self.problems if t == tab and (state is None or s == state))

    def part(self, host, name, default=None):
        value = (self.r.get(host) or {}).get(name)
        return default if value is None else value

    def series(self, pick, days=7):
        since = self.now - days * 86400
        return [pick(row) for row in self.history if row.get("at", 0) >= since]

    def growth(self, pick, days=7):
        values = [v for v in self.series(pick, days) if v is not None]
        return values[-1] - values[0] if len(values) >= 2 else None

    def run_state(self, service, tab, where):
        result = service.get("Result", "")
        if service.get("ActiveState") == "failed" or result not in ("", "success"):
            return self.flag("fail", tab, f"{where}: {service.get('Id')} ended with {result or 'failure'}")
        return "ok"

    # --- the checks, run once per page ------------------------------------------------------

    def check(self):
        for host in HOSTS:
            data = self.r[host]
            if data is None:
                self.flag("fail", "overview", f"{host} has sent no report")
            elif self.now - data.get("at", 0) > STALE:
                self.flag("fail", "overview", f"{host}'s report is {ago(data.get('at'), self.now)}")
            for u in self.part(host, "failed", []):
                self.flag("fail", host, f"{host}: {u.get('unit')} has failed")
            vitals = self.part(host, "vitals", {})
            mem = vitals.get("mem") or {}
            if vitals.get("temp") and vitals["temp"] > 85:
                self.flag("warn", host, f"{host}: CPU at {vitals['temp']:.0f} °C")
            if mem.get("total") and mem.get("available", 0) / mem["total"] < 0.1:
                self.flag("warn", host, f"{host}: under 10% of memory free")
            if vitals.get("load") and vitals.get("cpus") and vitals["load"][1] > vitals["cpus"] * 2:
                self.flag("warn", host, f"{host}: load {vitals['load'][1]} on {vitals['cpus']} CPUs")
        self.container_rows()
        self.timer_rows()
        self.site_rows()
        self.btrbk_rows()
        self.drive_view()
        self.cache_view()
        self.nix_view()
        self.disk_rows()
        self.raid_rows()
        self.smart_rows()
        self.btrfs_rows()
        for u in self.part("nest", "units", []):
            tab = "drive" if re.search(r"backup", u.get("Id", "")) else "nest"
            if u.get("ActiveState") != "active":
                self.flag("fail", tab, f"nest: {u.get('Id')} is {u.get('ActiveState')}")

    # --- servers ------------------------------------------------------------------------

    def machine_tile(self, host):
        data = self.r[host]
        if data is None:
            return tile(host, [("report", "none")], "fail")
        v = data.get("vitals") or {}
        mem = v.get("mem") or {}
        used = (mem.get("total", 0) - mem.get("available", 0)) / mem["total"] if mem.get("total") else 0
        state = self.worst([s for s, t, _ in self.problems if t == host] or ["ok"])
        if self.now - data.get("at", 0) > STALE:
            state = "fail"
        rows = [("report", e(ago(data.get("at"), self.now))), ("up", e(duration(v.get("uptime")))),
                ("load", e(" · ".join(str(x) for x in v.get("load", [])) + (f" on {v['cpus']} CPUs" if v.get("cpus") else ""))),
                ("memory", bar(used)[0] + f' <span class=mute>{size(mem.get("total", 0) - mem.get("available", 0))} of {size(mem.get("total"))}</span>'),
                ("CPU", e(f"{v['temp']:.0f} °C" if v.get("temp") is not None else "—")),
                ("failed units", str(len(data.get("failed") or []))), ("kernel", e(v.get("kernel", "—")))]
        return tile(host, rows, state)

    def overview(self):
        listing = "".join(
            f'<li>{dot(s)}{e(t)}<a href="{self.href(tab)}">{e(self.tab_label(tab))}</a></li>'
            for s, tab, t in sorted(self.problems, key=lambda p: -RANK[p[0]]))
        containers, _ = self.container_rows()
        up = sum(1 for c in self.part("hive", "containers", []) if c.get("active") == "active")
        sites = self.part("hive", "certs", [])
        sites_up = sum(1 for c in sites if 200 <= (c.get("code") or 0) < 500)
        body = f'<div class=grid>{self.machine_tile("hive")}{self.machine_tile("nest")}'
        body += tile("At a glance", [
            ("containers", f'{up} of {len(self.part("hive", "containers", []))} running'),
            ("sites", f"{sites_up} of {len([c for c in sites if c.get('code') is not None])} answering"),
            ("timers failed", str(self.count("timers", "fail"))),
            ("backups", "fine" if not self.count("backups", "fail") else f'{self.count("backups", "fail")} failed'),
        ]) + "</div>"
        body += section("Problems", f"<ul class=problems>{listing}</ul>" if listing else
                        '<div class="empty mute">nothing failed and nothing to look at</div>',
                        self.worst([s for s, _, _ in self.problems] or ["ok"]))
        return body

    def host_tab(self, host):
        data = self.r[host] or {}
        failed = [[dot("fail") + e(u.get("unit", "")), e(u.get("description", "")), badge("fail", u.get("sub", "failed"))]
                  for u in data.get("failed") or []]
        body = f'<div class=grid>{self.machine_tile(host)}</div>'
        body += section("Failed units", table(["unit", "what", ""], failed), "fail" if failed else "ok")
        if host == "nest":
            rows = [[dot("ok" if u.get("ActiveState") == "active" else "fail") + e(u.get("Id", "")), e(u.get("Description", "")),
                     badge("ok" if u.get("ActiveState") == "active" else "fail", u.get("SubState") or "?")]
                    for u in data.get("units") or []]
            body += section("Storage services", table(["unit", "what", ""], rows))
        v = data.get("vitals") or {}
        body += section("System", table(["", ""], [["system", e(v.get("system", "—"))], ["kernel", e(v.get("kernel", "—"))],
                                                   ["swap free", e(f'{size((v.get("mem") or {}).get("swap_free"))} of {size((v.get("mem") or {}).get("swap"))}')]]))
        return body

    def container_rows(self):
        stats = {s["unit"]: s for s in self.part("hive", "container_stats", []) if s.get("unit")}
        disk = {d["name"]: d["size"] for d in (self.sizes["hive"] or {}).get("container_disk") or []}
        rows, states = [], []
        for c in self.part("hive", "containers", []):
            unit = c.get("unit", "")
            name = unit.removeprefix("container@").removesuffix(".service")
            s = stats.get(unit, {})
            up = c.get("active") == "active"
            state = self.flag("ok" if up else "fail", "containers", f"hive: container {name} is {c.get('active')}")
            restarts = number(s.get("NRestarts")) or 0
            if up and restarts > 3:
                state = self.flag("warn", "containers", f"hive: container {name} restarted {restarts} times")
            states.append(state)
            since = stamp(s.get("ActiveEnterTimestamp"))
            cpu = number(s.get("CPUUsageNSec"))
            rows.append([dot(state) + e(name), badge(state, c.get("sub", "")), e(duration(self.now - since) if since and up else "—"),
                         e(size(number(s.get("MemoryCurrent")))), e(size(number(s.get("MemoryPeak")))),
                         e(duration(cpu / 1e9) if cpu else "—"), e(s.get("TasksCurrent", "—")), str(restarts),
                         e(size(disk.get(name))), spark(self.series(lambda r, n=name: (r.get("containers") or {}).get(n), 30))])
        return rows, self.worst(states)

    def containers_tab(self):
        rows, state = self.container_rows()
        return section("Containers on hive", table(["container", "state", "up", "memory", "peak", "CPU time", "tasks", "restarts", "disk", "disk, 30 days"],
                                                   rows, numeric=(3, 4, 5, 6, 7, 8)), state)

    def all_timers(self):
        """Every timer on both machines and inside hive's containers: (where, timer)."""
        out = [(h, t) for h in HOSTS for t in self.part(h, "timers", [])]
        out += [(t.get("machine", "?"), t) for t in self.part("hive", "inner_timers", [])]
        return out

    def timer_rows(self, only=None):
        rows, states = [], []
        for where, t in self.all_timers():
            name = t.get("activates", "").removesuffix(".service")
            if only and not only.search(name):
                continue
            service = t.get("service") or {}
            last = (t.get("last") or 0) / 1e6
            # A failed backup job counts on the Backups tab, every other one on Timers.
            state = self.run_state(service, "backups" if BACKUP_JOB.search(name) else "timers", where) if last else "none"
            states.append(state)
            nxt = (t.get("next") or 0) / 1e6
            rows.append((RANK[state], where, [dot(state) + e(name), e(where), e(ago(last, self.now)),
                                              e(ago(nxt, self.now) if nxt else "—"), badge(state, service.get("Result") or "not run")]))
        rows.sort(key=lambda r: (-r[0], r[1]))
        return [r[2] for r in rows], self.worst(states)

    def timers_tab(self):
        rows, state = self.timer_rows()
        return section("Every timer", table(["job", "on", "last run", "next run", "result"], rows), state,
                       "hive, nest and the containers on hive")

    def site_rows(self):
        rows, states = [], []
        for c in self.part("hive", "certs", []):
            start, until, code = c.get("from"), c.get("until"), c.get("code")
            site = code is not None
            states_here = []
            if site:
                states_here.append(self.flag("fail" if not code or code >= 500 else "ok", "sites",
                                             f"{c['name']} answers {code or 'nothing'}"))
            if not until:
                states_here.append(self.flag("fail", "sites", f"{c['name']}: no certificate could be read"))
            elif until < self.now:
                states_here.append(self.flag("fail", "sites", f"{c['name']}: certificate expired {ago(until, self.now)}"))
            elif start and (until - self.now) < (until - start) / 4:
                states_here.append(self.flag("warn", "sites", f"{c['name']}: certificate expires {ago(until, self.now)}"))
            state = self.worst(states_here or ["ok"])
            states.append(state)
            issuer = re.sub(r".*CN *= *", "", c.get("issuer") or "") or "—"
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(until)) if until else "—"
            rows.append([dot(state) + e(c["name"]), e(str(code) if site else "—"),
                         e(f"{c['took'] * 1000:.0f} ms" if site and c.get("took") else "—"), e(issuer), e(when),
                         e(ago(until, self.now) if until else "—"), badge(state)])
        return rows, self.worst(states)

    def sites_tab(self):
        rows, state = self.site_rows()
        return section("Sites and certificates", table(["name", "HTTP", "answer", "issuer", "expires", "left", ""], rows,
                                                       numeric=(1, 2)), state, "as hive sees them")

    # --- storage ------------------------------------------------------------------------

    def newest(self, names, share):
        times = []
        for name in names:
            m = re.fullmatch(re.escape(share) + r"\.(\d{8}T\d{4})(_\d+)?", name)
            if m:
                times.append(time.mktime(time.strptime(m[1], "%Y%m%dT%H%M")))
        return (max(times) if times else None), len(times)

    def shares_tab(self):
        du = (self.sizes["nest"] or {}).get("shares_du") or {}
        snaps = {s["share"]: s for s in du.get("snapshots") or []}
        drive = {s["share"]: s for s in du.get("drive") or []}
        rows = []
        for s in sorted(du.get("live") or [], key=lambda s: -s.get("total", 0)):
            n = s["share"]
            sn, dr = snaps.get(n, {}), drive.get(n, {})
            kept = "backed up" if sn else ("not backed up" if n == "@cache-chunks" else "old, unused")
            grow = self.growth(lambda r, n=n: (r.get("shares") or {}).get(n))
            rows.append([e(n), e(size(s.get("total"))), e(size(s.get("exclusive"))), e(str(sn.get("count", 0))),
                         e(size(sn.get("exclusive")) if sn else "—"), e(size(dr.get("newest")) if dr else "—"),
                         e(("+" if (grow or 0) >= 0 else "") + size(grow) if grow is not None else "—"),
                         spark(self.series(lambda r, n=n: (r.get("shares") or {}).get(n))), badge("ok" if sn else "none", kept)])
        measured = (self.sizes["nest"] or {}).get("at")
        return section("Shares on nest", table(["share", "size", "its own", "snapshots", "held by snapshots", "newest on drive",
                                                "7 days", "7 days", ""], rows, numeric=(1, 2, 3, 4, 5, 6)), None,
                       f"measured {ago(measured, self.now)}" if measured else "not measured yet")

    def btrbk_rows(self):
        backups = self.part("nest", "backups")
        if not backups:
            return [], self.flag("fail", "backups", "nest sent no backup listing")
        rows, states = [], []
        if not backups.get("drive"):
            states.append(self.flag("fail", "drive", "the backup drive is not mounted on nest"))
        shares = sorted({n.split(".")[0] for n in backups.get("snapshots", []) + backups.get("copies", [])})
        for share in shares:
            snap, snaps = self.newest(backups.get("snapshots", []), share)
            copy, copies = self.newest(backups.get("copies", []), share)
            # A share btrbk no longer takes is retired, not failing.
            taken = backups.get("taken")
            if (share not in taken) if taken else (snap and self.now - snap > 2 * 86400):
                rows.append([dot("none") + e(share), e(ago(snap, self.now)), str(snaps), e(ago(copy, self.now)), str(copies),
                             badge("none", "retired")])
                continue
            s1 = "ok" if snap and self.now - snap < 2 * 3600 else self.flag("fail", "backups", f"{share}: no snapshot in the last 2 h")
            if copy is None:
                s2 = self.flag("warn", "backups", f"{share}: no copy on the backup drive yet")
            elif self.now - copy > 36 * 3600:
                s2 = self.flag("fail", "backups", f"{share}: newest copy on the drive is {ago(copy, self.now)}")
            else:
                s2 = "ok"
            state = self.worst([s1, s2])
            states.append(state)
            rows.append([dot(state) + e(share), e(ago(snap, self.now)), str(snaps), e(ago(copy, self.now)), str(copies), badge(state)])
        return rows, self.worst(states)

    def backups_tab(self):
        btrbk, s1 = self.btrbk_rows()
        jobs, s2 = self.timer_rows(BACKUP_JOB)
        newest = []
        backups = self.part("nest", "backups") or {}
        for share in sorted({n.split(".")[0] for n in backups.get("copies", [])}):
            copy, _ = self.newest(backups.get("copies", []), share)
            newest.append([e(share), e(time.strftime("%Y-%m-%d %H:%M", time.localtime(copy)) if copy else "—"), e(ago(copy, self.now))])
        body = section("btrbk: snapshots on nest and copies on the drive",
                       table(["share", "newest snapshot", "snapshots", "newest on drive", "on drive", ""], btrbk, numeric=(2, 4)), s1)
        body += section("Backup jobs", table(["job", "on", "last run", "next run", "result"], jobs), s2,
                        "every machine and container")
        body += section("Restore points on the drive", table(["share", "newest copy", ""], newest), None)
        return body

    def drive_view(self):
        nest = self.r["nest"] or {}
        disk = next((d for d in nest.get("disks") or [] if d.get("target") == "/mnt/backup"), None)
        state = "ok"
        if disk and disk.get("size"):
            share = disk["used"] / disk["size"]
            state = self.flag(bar(share)[1], "drive", f"the backup drive is {share:.0%} full")
        for fs in nest.get("btrfs_errors") or []:
            if fs.get("mount") == "/mnt/backup" and fs.get("errors"):
                state = self.flag("fail", "drive", f"the backup drive has {fs['errors']} btrfs errors")
        return disk, state

    def drive_tab(self):
        nest = self.r["nest"] or {}
        disk, state = self.drive_view()
        du = (self.sizes["nest"] or {}).get("shares_du") or {}
        grow = self.growth(lambda r: (r.get("disks") or {}).get("nest:/mnt/backup"), 30)
        rows = []
        if disk:
            rows = [["used", bar(disk["used"] / disk["size"])[0] + f' {size(disk["used"])} of {size(disk["size"])}'],
                    ["free", e(size(disk["avail"]))], ["30 days", e(("+" if (grow or 0) >= 0 else "") + size(grow) if grow is not None else "—")],
                    ["history", spark(self.series(lambda r: (r.get("disks") or {}).get("nest:/mnt/backup"), 30), 200, 28)]]
        if grow and grow > 0 and disk:
            days = disk["avail"] / (grow / 30)
            rows.append(["full in", e(f"about {days / 30:.0f} months" if days > 60 else f"about {days:.0f} days")])
        body = section("The backup drive", table(["", ""], rows) if rows else '<div class="empty mute">not mounted</div>', state, "/mnt/backup on nest, LUKS and btrfs")
        copies = [[e(d["share"]), str(d.get("count", 0)), e(size(d.get("newest"))), e(size(d.get("exclusive")))]
                  for d in du.get("drive") or []]
        body += section("Copies per share", table(["share", "copies", "newest copy", "held by older copies"], copies, numeric=(1, 2, 3)))
        units = [[dot("ok" if u.get("ActiveState") == "active" else "fail") + e(u.get("Id", "")), e(u.get("Description", "")),
                  badge("ok" if u.get("ActiveState") == "active" else "fail", u.get("SubState") or "?")]
                 for u in nest.get("units") or [] if "backup" in u.get("Id", "")]
        errors = next((f.get("errors") for f in nest.get("btrfs_errors") or [] if f.get("mount") == "/mnt/backup"), None)
        scrub = next((s.get("text", "") for s in nest.get("scrub") or [] if s.get("mount") == "/mnt/backup"), "")
        summary = "\n".join(l.strip() for l in scrub.splitlines() if re.match(r"\s*(Status|Scrub started|Error summary)", l))
        body += section("Health", table(["", ""], [["btrfs errors", e(str(errors) if errors is not None else "—")],
                                                   ["last check", f"<pre>{e(summary) or '—'}</pre>"],
                                                   ["drive health", badge("none", "not available over USB")]] + [[u[0], u[2]] for u in units]))
        return body

    def cache_view(self):
        stats = self.part("hive", "cache_stats")
        if not stats:
            return None, self.flag("warn", "cache", "hive sent no cache numbers")
        state = "ok"
        runs = []
        for line in stats.get("gc") or []:
            text = line.get("text", "")
            if text.startswith("Starting"):
                runs.append({"at": line["at"], "deleted": 0, "passes": 0, "result": "running"})
            elif runs and "deleting:" in text:
                runs[-1]["deleted"] += 1
            elif runs and "deleted chunks left" in text:
                runs[-1]["passes"] += 1
            elif runs and text.startswith("Finished"):
                runs[-1]["result"] = "success"
            elif runs and ("Failed" in text or "failed" in text):
                runs[-1]["result"] = "failed"
        if runs and runs[-1]["result"] == "failed":
            state = self.flag("fail", "cache", "the last cache cleanup failed")
        pending = sum(c.get("count", 0) for c in stats.get("chunks") or [] if c.get("state") == "D")
        if pending:
            self.flag("warn", "cache", f"{pending} cache chunks are waiting to be deleted")
        return {"stats": stats, "runs": runs}, state

    def cache_tab(self):
        view, state = self.cache_view()
        if not view:
            return section("Cache", '<div class="empty mute">no numbers from hive yet</div>', state)
        stats = view["stats"]
        chunks = {c["state"]: c for c in stats.get("chunks") or []}
        pins = self.part("hive", "pins", [])
        per_cache = {}
        for p in pins:
            for c in p.get("caches") or []:
                per_cache[c] = per_cache.get(c, 0) + 1
        week = stats.get("week") or {}
        nars = stats.get("nars") or {}
        stored = (chunks.get("V") or {}).get("size", 0)
        body = '<div class=grid>' + tile("Stored", [
            ("on disk", f'<span class=big>{e(size(stored))}</span>'), ("chunks", e(f'{(chunks.get("V") or {}).get("count", 0):,}')),
            ("packages", e(f'{nars.get("count", 0):,} · {size(nars.get("size"))} unpacked')),
            ("30 days", spark(self.series(lambda r: r.get("chunks"), 30), 160, 26))]) + tile("This week", [
            ("pushed", e(f'{week.get("objects", 0):,} paths')), ("their size", e(size(week.get("size")))),
            ("growth", e(("+" if (self.growth(lambda r: r.get("chunks")) or 0) >= 0 else "") + size(self.growth(lambda r: r.get("chunks"))) if self.growth(lambda r: r.get("chunks")) is not None else "—"))]) + tile("Cleanup", [
            ("waiting to delete", e(f'{(chunks.get("D") or {}).get("count", 0):,} chunks')),
            ("unused packages", e(f'{nars.get("unheld") or 0:,}')),
            ("last run", e(ago(view["runs"][-1]["at"], self.now) if view["runs"] else "none in 30 days"))], state) + "</div>"
        rows = []
        for c in stats.get("caches") or []:
            rows.append([e(c["name"]), e(f'{c.get("objects", 0):,}'), e(size(c.get("size"))), str(per_cache.get(c["name"], 0)),
                         e(c.get("newest") or "—"), spark(self.series(lambda r, n=c["name"]: (r.get("cache") or {}).get(n), 30))])
        body += section("Caches", table(["cache", "paths", "size", "pins", "newest push", "30 days"], rows, numeric=(1, 2, 3)))
        runs = [[e(time.strftime("%Y-%m-%d %H:%M", time.localtime(r["at"]))), str(r["deleted"]), str(r["passes"]),
                 badge("ok" if r["result"] == "success" else "fail" if r["result"] == "failed" else "none", r["result"])]
                for r in reversed(view["runs"][-15:])]
        body += section("Cleanup runs (attic-gc)", table(["started", "unpinned paths dropped", "passes", "result"], runs, numeric=(1, 2)),
                        state, "nightly, keeps every pinned build and its closure")
        return body

    def nix_view(self):
        states = []
        for where, t in self.all_timers():
            if t.get("activates") == "nix-gc.service" and (t.get("last") or 0):
                states.append(self.run_state(t.get("service") or {}, "nix", where))
        return self.worst(states)

    def nix_tab(self):
        state = self.nix_view()
        tiles, logs = "", []
        for host in HOSTS:
            store = self.part(host, "nix_store") or {}
            # The filesystem the store lives on: the longest mount that holds /nix/store.
            disks = self.part(host, "disks", [])
            holding = [d for d in disks if d["target"] == "/" or "/nix/store".startswith(d["target"] + "/")]
            fs = max(holding, key=lambda d: len(d["target"]), default=None)
            gc = next((t for w, t in self.all_timers() if w == host and t.get("activates") == "nix-gc.service"), {})
            tiles += tile(host, [("store", f'<span class=big>{e(size(store.get("size")))}</span>'),
                                 ("paths", e(f'{store.get("paths", 0):,}')),
                                 ("its disk", bar(fs["used"] / fs["size"])[0] + f' <span class=mute>{e(fs["target"])}</span>' if fs else "—"),
                                 ("30 days", spark(self.series(lambda r, h=host: (r.get("nix") or {}).get(h), 30), 160, 26)),
                                 ("nix-gc", e(f'last {ago((gc.get("last") or 0) / 1e6, self.now)}, next {ago((gc.get("next") or 0) / 1e6, self.now)}' if gc else "no timer"))])
            for line in reversed(store.get("gc") or []):
                logs.append([e(host), e(time.strftime("%Y-%m-%d %H:%M", time.localtime(line["at"]))), e(line["text"])])
        body = f'<div class=grid>{tiles}</div>'
        body += section("What nix-gc freed", table(["on", "when", ""], logs[:30]), state, "last 60 days")
        return body

    def disk_rows(self):
        rows, states = [], []
        for host in HOSTS:
            for d in self.part(host, "disks", []):
                share = d["used"] / d["size"] if d.get("size") else 0
                cell, state = bar(share)
                self.flag(state, "disks", f"{host}: {d['target']} is {share:.0%} full")
                states.append(state)
                key = f"{host}:{d['target']}"
                rows.append([dot(state) + e(host), e(d["target"]), e(d["source"]), cell, e(size(d["used"])), e(size(d["avail"])),
                             spark(self.series(lambda r, k=key: (r.get("disks") or {}).get(k), 30))])
        return rows, self.worst(states)

    def raid_rows(self):
        rows, states = [], []
        for host in HOSTS:
            for md in self.part(host, "raid", []):
                bad = md.get("degraded", "0") not in ("0", "") or md.get("state") not in ("clean", "active", "active-idle")
                state = self.flag("fail" if bad else "ok", "disks", f"{host}: {md['name']} is {md.get('state')}, degraded {md.get('degraded')}")
                states.append(state)
                rows.append([dot(state) + e(host), e(md["name"]), e(md.get("level", "")), e(md.get("state", "")),
                             e(md.get("degraded", "")), e(md.get("sync", "")), badge(state)])
        return rows, self.worst(states)

    def smart_rows(self):
        rows, states = [], []
        for host in HOSTS:
            for d in self.part(host, "smart", []):
                if d.get("usb"):
                    rows.append([dot("none") + e(host), e(d["dev"]), e(d.get("model") or ""), "—", "—", "—", "—",
                                 badge("none", "not available over USB")])
                    continue
                passed, temp, used = d.get("passed"), d.get("temp"), d.get("used")
                if passed is False or (d.get("media_errors") or 0) > 0:
                    state = self.flag("fail", "disks", f"{host}: {d['dev']} ({d.get('model')}) fails its health check")
                elif passed is None:
                    state = self.flag("warn", "disks", f"{host}: {d['dev']} gives no health report")
                elif (temp or 0) > 70 or (used or 0) > 80:
                    state = self.flag("warn", "disks", f"{host}: {d['dev']} is at {temp} °C, {used}% worn")
                else:
                    state = "ok"
                states.append(state)
                rows.append([dot(state) + e(host), e(d["dev"]), e(d.get("model") or ""), e(f"{temp} °C" if temp is not None else "—"),
                             e(f"{used}%" if used is not None else "—"), e(f"{d['hours']} h" if d.get("hours") is not None else "—"),
                             e(str(d.get("media_errors")) if d.get("media_errors") is not None else "—"),
                             badge(state, "passed" if passed else "failed" if passed is False else "unknown")])
        return rows, self.worst(states)

    def btrfs_rows(self):
        rows, states = [], []
        for host in HOSTS:
            scrubs = {s["mount"]: s.get("text", "") for s in self.part(host, "scrub", [])}
            for fs in self.part(host, "btrfs_errors", []):
                tab = "drive" if fs["mount"] == "/mnt/backup" else "disks"
                if not fs.get("mounted"):
                    state = self.flag("fail", tab, f"{host}: {fs['mount']} is not mounted")
                else:
                    state = self.flag("fail" if fs.get("errors") else "ok", tab, f"{host}: {fs['mount']} has {fs.get('errors')} btrfs errors")
                states.append(state)
                summary = "\n".join(l.strip() for l in scrubs.get(fs["mount"], "").splitlines()
                                    if re.match(r"\s*(Status|Scrub started|Error summary)", l))
                rows.append([dot(state) + e(host), e(fs["mount"]), e(str(fs.get("errors", "—"))), f"<pre>{e(summary) or '—'}</pre>", badge(state)])
        return rows, self.worst(states)

    def disks_tab(self):
        disks, s1 = self.disk_rows()
        raid, s2 = self.raid_rows()
        smart, s3 = self.smart_rows()
        btrfs, s4 = self.btrfs_rows()
        body = section("Filesystems", table(["on", "mount", "device", "used", "used", "free", "30 days"], disks, numeric=(4, 5)), s1)
        body += section("RAID", table(["on", "array", "level", "state", "degraded", "sync", ""], raid), s2)
        body += section("Drives", table(["on", "drive", "model", "temperature", "worn", "powered on", "media errors", "health"], smart), s3)
        body += section("btrfs errors and checks", table(["on", "filesystem", "errors", "last check", ""], btrfs), s4)
        return body

    # --- page frame -----------------------------------------------------------------------

    @staticmethod
    def owner(tab):
        for key, (_, _, tabs) in SECTIONS.items():
            if tab in [t[0] for t in tabs]:
                return key
        return "servers"

    def href(self, tab):
        return f"/{self.owner(tab)}/{tab}"

    def tab_label(self, tab):
        for _, (_, _, tabs) in SECTIONS.items():
            for key, label, _ in tabs:
                if key == tab:
                    return label
        return tab

    def band(self, key, active):
        title, icon, tabs = SECTIONS[key]
        own = [t[0] for t in tabs]
        fails = sum(1 for s, t, _ in self.problems if s == "fail" and t in own)
        warns = sum(1 for s, t, _ in self.problems if s == "warn" and t in own)
        ages = " · ".join(f"{h} {ago((self.r[h] or {}).get('at'), self.now)}" for h in HOSTS)
        links = ""
        for tab, label, tab_icon in tabs:
            n_fail, n_warn = self.count(tab, "fail"), self.count(tab, "warn")
            count = (f'<span class="count fail">{n_fail}</span>' if n_fail else
                     f'<span class="count warn">{n_warn}</span>' if n_warn else "")
            links += f'<a href="/{key}/{tab}" class="{"on" if tab == active else ""}">{ICON[tab_icon]}<span class=label>{e(label)}</span>{count}</a>'
        head = (f'<div class=head><div class=title>{ICON[icon]}{e(title)}</div><div class=summary>'
                f'{badge("fail" if fails else "ok", f"{fails} failed")}{badge("warn" if warns else "ok", f"{warns} to look at")}'
                f'<span class=mute>reports: {e(ages)}</span></div></div>')
        return f'<div class=band>{head}<div class=tabs>{links}</div></div>'

    def render(self, key, tab):
        self.check()
        views = {"overview": self.overview, "hive": lambda: self.host_tab("hive"), "nest": lambda: self.host_tab("nest"),
                 "containers": self.containers_tab, "timers": self.timers_tab, "sites": self.sites_tab,
                 "shares": self.shares_tab, "backups": self.backups_tab, "drive": self.drive_tab,
                 "cache": self.cache_tab, "nix": self.nix_tab, "disks": self.disks_tab}
        body = views[tab]()
        # A view's own checks may add problems; the band counts them all.
        return self.band(key, tab) + body


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        # Caddy strips these from visitors; only the login proxy sets them.
        name = self.headers.get("X-Forwarded-Preferred-Username") or self.headers.get("X-Forwarded-User")
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if not name:
            return self.reply(403, "sign in", '<div class="card empty">sign in on id.bresilla.com first</div>', name, "servers")
        if not parts:
            return self.redirect("/servers/overview")
        key = parts[0]
        if key not in SECTIONS or len(parts) > 2:
            return self.reply(404, "not found", '<div class="card empty">not found</div>', name, "servers")
        tabs = [t[0] for t in SECTIONS[key][2]]
        if len(parts) == 1:
            return self.redirect(f"/{key}/{tabs[0]}")
        if parts[1] not in tabs:
            return self.reply(404, "not found", '<div class="card empty">not found</div>', name, key)
        title = f"{dict((t[0], t[1]) for t in SECTIONS[key][2])[parts[1]]} · {SECTIONS[key][0]}"
        self.reply(200, title, Report().render(key, parts[1]), name, key)

    def redirect(self, to):
        self.send_response(302)
        self.send_header("Location", to)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def reply(self, code, title, body, name, active):
        links = [(k, f"/{k}", v[0]) for k, v in SECTIONS.items()]
        page = site_ui.page(site="status", title=title, body=body, links=links, active=active, name=name,
                            here=self.path, style=STYLE, script=SCRIPT).encode()
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
