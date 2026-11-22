"""status.bresilla.com: hive and nest, read-only, in two layouts that switch beside the account.

By machine (the default) the top bar is hive and nest, each tab about that one machine.
By function it is Servers and Storage, each tab across both. Hive and nest write their
reports (collect.sh) every five minutes, their sizes and a line of history every hour;
this page only reads them.
"""

import calendar
import hmac
import html
import json
import os
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

import site_ui

DATA = Path(os.environ.get("STATUS_DATA", "/var/lib/status"))
LISTEN = os.environ.get("STATUS_LISTEN", "127.0.0.1:8093")
STALE = 15 * 60
LIVE_STALE = 3 * 60
HOSTS = ("hive", "nest")
HIVE, NEST, BOTH = ("hive",), ("nest",), HOSTS
# dump: the backup targets, edited here (admins only) and kept in DUMP_DIR, where nest's
# manager reads them; all of them reported under one name, dump.
DUMP_DIR = Path(os.environ.get("STATUS_DUMP", "/var/lib/dump"))
DUMP = ("dump",)
TARGETS, MANAGER = {}, {}
RANK = {"ok": 0, "none": 0, "warn": 1, "fail": 2}
BACKUP_JOB = re.compile(r"backup|btrbk|scrub|keep|dump")
COOKIE = "status_view"
e = html.escape


# A tab: (key, label, icon, the view that draws it, the topics its badge counts, the machines it covers).
# A topic is what a problem is about; "*" counts every problem of the tab's machines.
def build_views(targets):
    return {
        "machine": ("by machine", {
            "hive": ("hive", "server", [
                ("overview", "Overview", "overview", "overview", ("*",), HIVE),
                ("containers", "Containers", "box", "containers", ("containers",), HIVE),
                ("timers", "Timers", "clock", "timers", ("timers", "backups"), HIVE),
                ("sites", "Sites", "globe", "sites", ("sites",), HIVE),
                ("cache", "Cache", "database", "cache", ("cache",), HIVE),
                ("nix", "Nix", "snow", "nix", ("nix",), HIVE),
                ("disks", "Disks", "disk", "disks", ("disks",), HIVE)]),
            "nest": ("nest", "drive", [
                ("overview", "Overview", "overview", "overview", ("*",), NEST),
                ("shares", "Shares", "folder", "shares", ("shares",), NEST),
                ("backups", "Backups", "history", "backups", ("backups",), NEST),
                ("nix", "Nix", "snow", "nix", ("nix",), NEST),
                ("disks", "Disks", "disk", "disks", ("disks",), NEST)]),
            # dump: the backup targets, an overview and a tab of its own for each.
            "dump": ("dump", "drive", [("overview", "Overview", "overview", "dump", ("*",), DUMP)] +
                     [(name, name, "drive" if t.get("kind") == "btrbk" else "database", f"target:{name}", (name,), DUMP)
                      for name, t in targets.items()]),
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
                ("dump", "Dump", "drive", "dump", tuple(targets) or ("dump",), DUMP),
                ("cache", "Cache", "database", "cache", ("cache",), HIVE),
                ("nix", "Nix", "snow", "nix", ("nix",), BOTH),
                ("disks", "Disks", "disk", "disks", ("disks",), BOTH)]),
        }),
    }
VIEWS, SECTIONS = build_views({}), {}


def refresh():
    """The target list and nest's manager state, read again for each request."""
    global TARGETS, MANAGER, VIEWS, SECTIONS
    TARGETS = load_dump("targets.json")
    MANAGER = load_dump("agents.json").get("manager") or {}
    VIEWS = build_views(TARGETS)
    SECTIONS = {key: (view, *section) for view, (_, sections) in VIEWS.items() for key, section in sections.items()}


def load_dump(name):
    try:
        data = json.loads((DUMP_DIR / name).read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}

ICON = {name: site_ui.icon(name) for name in site_ui.ICONS}
STYLE = site_ui.STYLE + """
/* The by machine / by function switch beside the account. */
.switch { display: inline-flex; border: 1px solid var(--line); border-radius: 999px; overflow: hidden; margin-right: var(--s3); }
.switch a { padding: 0 10px; line-height: 24px; font-size: var(--site-font-tiny); color: var(--mute); text-decoration: none; }
.switch a.on { background: color-mix(in srgb, var(--accent) 18%, transparent); color: var(--fg); }
/* Adding a target: only the fields of the kind picked show. */
form:has(input[name=kind][value=btrbk]:checked) .for-restic,
form:has(input[name=kind][value=restic]:checked) .for-btrbk { display: none; }
.key-box { display: flex; gap: var(--s2); align-items: flex-start; }
.key-box pre { flex: 1; }
.steps { margin: 0; padding-left: 1.4em; display: grid; gap: var(--s2); }
"""
# Fresh every 30 s, but never while a panel is open or a field is being filled in.
SCRIPT = site_ui.SCRIPT + """setInterval(() => {
  const busy = document.querySelector("details.reveal[open]") || document.activeElement?.matches("input, select, textarea");
  if (!busy) location.reload();
}, 30000);
document.addEventListener("click", (event) => {
  const id = event.target.closest("[data-copy]")?.dataset.copy;
  if (id) navigator.clipboard?.writeText(document.getElementById(id).textContent);
});"""


def load(name):
    try:
        return json.loads((DATA / name).read_text())
    except (OSError, ValueError):
        return None


def merged(host):
    """A machine's slow report (every 5 min) with its live one (every 30 s) over it;
    `at` is the live one's time, `slow_at` the slow one's."""
    slow, live = load(f"{host}.json"), load(f"{host}-live.json")
    if slow is None and live is None:
        return None
    out = dict(slow or {})
    out.update(live or {})
    out["slow_at"] = (slow or {}).get("at")
    out["at"] = (live or slow).get("at")
    out["live"] = live is not None
    return out


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


# The page parts every site shares (services/ui).
badge, dot, bar, spark = site_ui.pill, site_ui.dot, site_ui.bar, site_ui.spark
table, section, tile = site_ui.table, site_ui.section, site_ui.tile


def on(hosts):
    """A column naming the machine, only where a tab covers both."""
    return len(hosts) > 1


class Report:
    """Both machines' reports. Every check runs once and notes each problem with its
    topic and machine; a tab's badge counts the problems its topics and machines match."""

    def __init__(self, admin=False, csrf=""):
        self.admin, self.csrf = admin, csrf
        self.now = time.time()
        self.problems = []
        self.r = {h: merged(h) for h in HOSTS}
        self.sizes = {h: load(f"{h}-sizes.json") for h in HOSTS}
        self.dumped = {name: load(f"dump-{name}.json") for name in TARGETS}
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
            elif data["live"] and self.now - data.get("at", 0) > LIVE_STALE:
                self.flag("fail", "host", host, f"{host}'s live state is {ago(data.get('at'), self.now)}")
            elif self.now - (data.get("slow_at") or data.get("at", 0)) > STALE:
                self.flag("fail", "host", host, f"{host}'s report is {ago(data.get('slow_at') or data.get('at'), self.now)}")
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
                self.flag("fail", "host", "nest",
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
        self.check_targets()
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
                times.append(calendar.timegm(time.strptime(m[1], "%Y%m%dT%H%M")))
        return (max(times) if times else None), len(times)

    def btrbk_shares(self):
        """Each share nest's btrbk knows of: (share, newest snapshot, count, retired)."""
        backups = self.part("nest", "backups") or {}
        snaps, taken = backups.get("snapshots", []), backups.get("taken")
        out = []
        for share in sorted({n.split(".")[0] for n in snaps}):
            snap, n_snap = self.newest(snaps, share)
            # A share btrbk no longer takes is retired, not failing.
            retired = (share not in taken) if taken else bool(snap and self.now - snap > 2 * 86400)
            out.append((share, snap, n_snap, retired))
        return out

    def taken(self):
        return [s[0] for s in self.btrbk_shares() if not s[3]]

    def check_btrbk(self):
        if not self.part("nest", "backups"):
            self.flag("fail", "backups", "nest", "nest sent no backup listing")
            return
        for share, snap, _, retired in self.btrbk_shares():
            if not retired and not (snap and self.now - snap < 2 * 3600):
                self.flag("fail", "backups", "nest", f"{share}: no snapshot in the last 2 h")

    # --- the dump targets ----------------------------------------------------------------

    def copies(self, name):
        """A btrbk target's copies: {share: (newest, count)} for every share nest snapshots."""
        listed = (self.dumped.get(name) or {}).get("copies", [])
        return {share: self.newest(listed, share) for share in self.taken()}

    def target_disk(self, name):
        return (self.dumped.get(name) or {}).get("disk")

    def state(self, name):
        """What nest's manager last said about a target: its state, a detail, the disks it saw."""
        return (MANAGER.get("targets") or {}).get(name) or {}

    def check_targets(self):
        for name, t in TARGETS.items():
            if t.get("state") == "removed":
                continue
            st = self.state(name)
            where = t.get("host") or t.get("repository") or "?"
            if not st:
                self.flag("warn", name, "dump", f"{name}: nest has not set it up yet")
                continue
            if st.get("state") == "error":
                self.flag("fail", name, "dump", f"{name}: {st.get('detail') or 'failed'}")
                continue
            if st.get("state") == "pick-disk":
                self.flag("warn", name, "dump", f"{name}: {st.get('detail') or 'pick its disk'}")
                continue
            report = self.dumped.get(name)
            if report is None:
                self.flag("warn", name, "dump", f"{name}: no report yet")
                continue
            if self.now - report.get("at", 0) > STALE:
                self.flag("fail", name, "dump", f"{name}: report is {ago(report.get('at'), self.now)}")
            if t.get("kind") == "restic":
                last = report.get("restic")
                if not last:
                    self.flag("warn", name, "dump", f"{name}: no backup to {where} yet")
                elif not last.get("ok"):
                    self.flag("fail", name, "dump", f"{name}: the last backup to {where} failed")
                elif self.now - last.get("at", 0) > 36 * 3600:
                    self.flag("fail", name, "dump", f"{name}: the last backup is {ago(last['at'], self.now)}")
                continue
            if not report.get("mounted"):
                self.flag("fail", name, "dump", f"{name}: its disk is not mounted on {where}")
            push = report.get("push")
            if push and not push.get("ok"):
                self.flag("fail", name, "dump", f"{name}: the last push failed")
            disk = self.target_disk(name)
            if disk and disk.get("size"):
                share = disk["used"] / disk["size"]
                self.flag(bar(share)[1], name, "dump", f"{name}: its disk is {share:.0%} full")
            if report.get("btrfs_errors"):
                self.flag("fail", name, "dump", f"{name}: {report['btrfs_errors']} btrfs errors on its disk")
            for share, (copy, _) in self.copies(name).items():
                if copy is None:
                    self.flag("warn", name, "dump", f"{name}: no copy of {share} yet")
                elif self.now - copy > 36 * 3600:
                    self.flag("fail", name, "dump", f"{name}: newest copy of {share} is {ago(copy, self.now)}")

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
                topic = "disks"
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
        snap = max((s[1] for s in self.btrbk_shares() if s[1] and not s[3]), default=None)
        rows = [("shares", e(f'{len(du.get("live") or [])}, {size(sum(s.get("total", 0) for s in du.get("live") or []))}')),
                ("newest snapshot", e(ago(snap, self.now)))]
        # The oldest of each target's newest copies: how far behind that target is.
        for name, t in TARGETS.items():
            if t.get("kind") == "btrbk" and t.get("state") != "removed":
                newest = [c[0] for c in self.copies(name).values()]
                rows.append((f"on {name}", e("—" if not newest or None in newest else ago(min(newest), self.now))))
        rows.append(("Nix store", e(size((self.part("nest", "nix_store") or {}).get("size")))))
        return tile("nest at a glance", rows)

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
        taken = set(self.taken())
        rows = []
        for s in sorted(du.get("live") or [], key=lambda s: -s.get("total", 0)):
            n = s["share"]
            sn = snaps.get(n, {})
            kept = badge("ok", "backed up") if n in taken else badge("none", "not backed up" if n == "@cache-chunks" else "retired")
            rows.append([e(n), e(size(s.get("total"))), e(size(s.get("exclusive"))), e(str(sn.get("count", 0))),
                         e(size(sn.get("exclusive")) if sn else "—"),
                         e(change(self.growth(lambda r, n=n: (r.get("shares") or {}).get(n)))),
                         spark(self.series(lambda r, n=n: (r.get("shares") or {}).get(n))), kept])
        measured = (self.sizes["nest"] or {}).get("at")
        return section("Shares on nest", table(["share", "size", "its own", "snapshots", "held by snapshots", "7 days", "7 days", ""],
                                               rows, numeric=(1, 2, 3, 4, 5)), None,
                       f"measured {ago(measured, self.now)}" if measured else "not measured yet")

    def backups(self, hosts, view):
        """nest's snapshots, and how far each dump target has copied them."""
        body = ""
        if "nest" in hosts:
            pulled = [n for n, t in TARGETS.items() if t.get("kind") == "btrbk" and t.get("state") != "removed"]
            got = {n: self.copies(n) for n in pulled}
            rows = []
            for share, snap, n_snap, retired in self.btrbk_shares():
                if retired:
                    rows.append([dot("none") + e(share), e(ago(snap, self.now)), str(n_snap)] + ["—"] * len(pulled) + [badge("none", "retired")])
                    continue
                states = ["ok" if snap and self.now - snap < 2 * 3600 else "fail"]
                cells = []
                for n in pulled:
                    copy, count = got[n].get(share, (None, 0))
                    states.append("warn" if copy is None else "fail" if self.now - copy > 36 * 3600 else "ok")
                    cells.append(e(f"{ago(copy, self.now)} · {count}" if copy else "none yet"))
                state = self.worst(states)
                rows.append([dot(state) + e(share), e(ago(snap, self.now)), str(n_snap)] + cells + [badge(state)])
            body += section("Snapshots on nest, and copies on each dump target",
                            table(["share", "newest snapshot", "snapshots"] + [f"on {n}" for n in pulled] + [""], rows, numeric=(2,)),
                            self.worst([p[0] for p in self.matching(("backups",) + tuple(pulled), ("nest", "dump"))] or ["ok"]),
                            "copies: newest · how many")
        jobs = [t for t in self.all_timers(hosts) if BACKUP_JOB.search(t[2].get("activates", ""))]
        body += section("Backup jobs", self.timer_table(jobs), self.state_of(("backups",), hosts),
                        "nest's own" if hosts == NEST else "every machine and container")
        return body

    def target_tile(self, name, link=True):
        t, report, st = TARGETS[name], self.dumped.get(name) or {}, self.state(name)
        removed = t.get("state") == "removed"
        state = "none" if removed else self.state_of((name,), DUMP)
        label = "removed" if removed else {"ready": "ready", "pick-disk": "pick a disk", "error": "error",
                                           "wiped": "wiped"}.get(st.get("state"), "setting up")
        # Set up, but something about it is wrong: say so rather than "ready".
        if label == "ready" and state in ("warn", "fail"):
            label = "failing" if state == "fail" else "look at it"
        rows = [("kind", e("disk over SSH" if t.get("kind") == "btrbk" else "restic repository")),
                ("where", e(t.get("host") or t.get("repository") or "?"))]
        if t.get("kind") == "btrbk":
            disk = self.target_disk(name)
            rows.append(("disk", bar(disk["used"] / disk["size"])[0] + f' <span class=mute>{size(disk["used"])} of {size(disk["size"])}</span>'
                         if disk and disk.get("size") else "—"))
            push = report.get("push") or {}
            rows.append(("last push", e(f'{ago(push["at"], self.now)}, {"ok" if push.get("ok") else "failed"}' if push else "not yet")))
        else:
            last = report.get("restic") or {}
            rows.append(("last backup", e(f'{ago(last["at"], self.now)}, {"ok" if last.get("ok") else "failed"}' if last else "not yet")))
        rows.append(("keeps", e(t.get("keep") or "—")))
        return tile(name, rows, state, href=f"/dump/{name}" if link else None, note=badge(state, label))

    def form(self, action, fields, button, danger=False):
        return (f'<form method=post action="{e(action)}" class=card style="max-width:720px;margin:0;border:0;padding:0;background:none">'
                f'<input type=hidden name=csrf value="{e(self.csrf)}">{fields}'
                f'<div class=actions><button class="{"danger" if danger else ""}">{e(button)}</button></div></form>')

    def add_form(self):
        return self.form("/-/dump/add",
            '<div class=options>'
            '<label class=choice><input type=radio name=kind value=btrbk checked> <b>A disk in a machine</b>'
            '<span>nest reaches it over SSH, formats the disk you pick and pushes btrbk copies each night</span></label>'
            '<label class=choice><input type=radio name=kind value=restic> <b>A repository online</b>'
            '<span>restic, encrypted on nest: Google Drive, OneDrive, B2 or anything rclone reaches</span></label></div>'
            '<div class=fields>'
            '<label for=t-name>name</label><input id=t-name name=name required pattern="[a-z0-9][a-z0-9-]{0,30}" placeholder="pc2">'
            '<label class=for-btrbk for=t-host>machine</label><input class=for-btrbk id=t-host name=host placeholder="pc2.netbird">'
            '<label class=for-btrbk for=t-user>its user</label><input class=for-btrbk id=t-user name=user value="dump">'
            '<label class=for-restic for=t-repo>repository</label>'
            '<input class=for-restic id=t-repo name=repository placeholder="rclone:gdrive:dump">'
            '<label for=t-keep>keep</label><input id=t-keep name=keep value="14d 8w 12m"></div>',
            "Add target")

    def setup_help(self):
        key = MANAGER.get("key") or "nest has not made its key yet"
        return (f'<p>nest logs in as <code>dump</code> with its key, limited to btrbk\'s filtered commands under '
                f'<code>/mnt/dump</code> and the <code>dump-target</code> helper (probe, format a confirmed blank disk, '
                f'mount, report, wipe).</p>'
                f'<div class=key-box><pre id=dumpkey>{e(key)}</pre>'
                f'<button type=button class="ghost small" data-copy=dumpkey>copy</button></div>'
                '<ol class=steps>'
                '<li><b>NixOS:</b> <code>bresilla.dump.target</code> on that machine, as in '
                '<code>devices/tron/default.nix</code>.</li>'
                '<li><b>Anything else:</b> the same by hand: the key with <code>restrict,command=</code> and <code>from=</code>, '
                'and <code>shared/services/dump/target.sh</code> as the helper.</li>'
                '<li><b>NetBird:</b> a rule letting nest reach it on port 22.</li></ol>')

    def dump(self, hosts, view):
        """Every target as a card, what is wrong with any, and (for admins) adding one."""
        active = [n for n, t in TARGETS.items() if t.get("state") != "removed"]
        removed = [n for n in TARGETS if n not in active]
        body = ""
        if self.admin:
            body += ('<div class=actions style="margin-bottom:var(--s4)">'
                     + site_ui.reveal("Add a target", self.add_form())
                     + site_ui.reveal("Getting a machine ready", self.setup_help(), ico="key", kind="ghost") + "</div>")
        body += ('<div class=grid>' + "".join(self.target_tile(n) for n in active) + "</div>") if active else \
            '<div class="card empty">no targets yet: add one above</div>'
        listing = "".join(
            f'<li>{dot(s)}{e(t)}<a href="/dump/{e(topic)}">{e(topic)}</a></li>'
            for s, topic, host, t in sorted(self.matching(tuple(TARGETS), DUMP), key=lambda p: -RANK[p[0]]))
        if listing:
            body += section("To look at", f"<ul class=problems>{listing}</ul>", self.state_of(tuple(TARGETS), DUMP))
        if removed:
            body += section("Removed", table(["target", "where", ""], [
                [f'<a href="/dump/{e(n)}">{e(n)}</a>', e(TARGETS[n].get("host") or TARGETS[n].get("repository") or "?"),
                 badge("none", "removed")] for n in removed]), None, "copies stay where they are until forgotten or wiped")
        if not self.admin:
            body += '<p class=mute>Only status admins on id.bresilla.com can add or remove targets.</p>'
        return body

    def disk_picker(self, name, st):
        options = ""
        for d in st.get("disks") or []:
            facts = f'{size(d.get("size"))} · serial {d.get("serial") or "?"} · {d.get("path")}'
            if d.get("blank") and d.get("id"):
                options += (f'<label class=choice><input type=radio name=disk value="{e(d["id"])}" required> '
                            f'<b>{e(d.get("model") or "disk")}</b><span>{e(facts)} · blank</span></label>')
            else:
                options += (f'<label class="choice off"><input type=radio disabled> <b>{e(d.get("model") or "disk")}</b>'
                            f'<span>{e(facts)} · in use, not offered</span></label>')
        return self.form(f"/-/dump/disk/{name}",
            f'<div class=options>{options or "<p class=mute>nest found no disks yet</p>"}</div>'
            '<div class=fields><label for=d-confirm>serial, to confirm</label>'
            '<input id=d-confirm name=confirm required autocomplete=off placeholder="the disk\'s serial, as shown"></div>'
            '<p class=mute>The disk picked is wiped: LVM and btrfs go on it, then nest starts sending copies.</p>',
            "Wipe and use this disk", danger=True)

    def target(self, name):
        t, report, st = TARGETS[name], self.dumped.get(name) or {}, self.state(name)
        removed = t.get("state") == "removed"
        body = ""
        if self.admin:
            acts = ""
            if removed:
                acts += site_ui.reveal("Forget it", self.form(f"/-/dump/forget/{name}",
                    "<p>Drops it from the list. Nothing on the disk or repository changes.</p>", "Forget"), ico="x", kind="ghost")
            else:
                wipe = ('<div class=fields><label for=r-wipe>also wipe the disk</label>'
                        '<input id=r-wipe name=wipe autocomplete=off placeholder="type its serial to wipe it"></div>'
                        if t.get("kind") == "btrbk" else "")
                acts += site_ui.reveal("Remove", self.form(f"/-/dump/remove/{name}",
                    "<p>nest stops sending copies here; what is there stays, unless you wipe it.</p>" + wipe, "Remove", danger=True),
                    ico="trash", kind="danger")
            body += f'<div class=actions style="margin-bottom:var(--s4)">{acts}</div>'
        body += f'<div class=grid>{self.target_tile(name, link=False)}</div>'
        if st.get("detail") and st.get("state") not in ("ready", "pick-disk"):
            body += f'<div class=flash>{e(st["detail"])}</div>'
        if removed:
            return body
        if t.get("kind") == "btrbk":
            if st.get("state") == "pick-disk":
                body += section("Pick its disk", self.disk_picker(name, st) if self.admin
                                else '<p class=mute>A status admin picks the disk here.</p>', "warn")
            if st.get("state") == "ready":
                rows = []
                for share, (copy, count) in sorted(self.copies(name).items()):
                    state = "warn" if copy is None else "fail" if self.now - copy > 36 * 3600 else "ok"
                    rows.append([dot(state) + e(share), e(when(copy)), e(ago(copy, self.now) if copy else "none yet"), str(count), badge(state)])
                body += section(f"Copies on {name}", table(["share", "newest copy", "", "copies", ""], rows, numeric=(3,)),
                                self.state_of((name,), DUMP), f"/mnt/dump/{name}/nest on {t.get('host')}")
                push = report.get("push") or {}
                body += section("Last push", f"<pre>{e(chr(10).join(push.get('output') or [])) or 'not yet'}</pre>",
                                "ok" if push.get("ok") else "fail" if push else None, ago(push.get("at"), self.now) if push else "")
        else:
            last = report.get("restic") or {}
            body += section("Last backup", f"<pre>{e(chr(10).join(last.get('output') or [])) or 'not yet'}</pre>",
                            "ok" if last.get("ok") else "fail" if last else None,
                            "rclone logs in once on nest: sudo rclone config --config /var/lib/dump/rclone.conf")
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
        items, seen = [], set()
        for tab, label, tab_icon, _, topics, hosts in tabs:
            found = self.matching(topics, hosts)
            seen.update(p[3] for p in found)
            fails, warns = sum(1 for p in found if p[0] == "fail"), sum(1 for p in found if p[0] == "warn")
            items.append((f"/{key}/{tab}", label, tab_icon, fails or warns, "fail" if fails else "warn", tab == active))
        mine = [p for p in self.problems if p[3] in seen]
        fails, warns = sum(1 for p in mine if p[0] == "fail"), sum(1 for p in mine if p[0] == "warn")
        covered = {h for t in tabs for h in t[5]}
        ages = [f"{h} {ago((self.r[h] or {}).get('at'), self.now)}" for h in HOSTS if h in covered]
        if "dump" in covered:
            ages += [f"{n} {ago((self.dumped.get(n) or {}).get('at'), self.now)}" for n, t in TARGETS.items()
                     if t.get("state") != "removed"]
        summary = (badge("fail" if fails else "ok", f"{fails} failed") + badge("warn" if warns else "ok", f"{warns} to look at")
                   + (f'<span class=mute>reported {e(" · ".join(ages))}</span>' if ages else ""))
        return site_ui.band(title, icon, summary=summary, items=items)

    def render(self, key, tab, flash=""):
        view, _, _, tabs = SECTIONS[key]
        _, _, _, draw, _, hosts = next(t for t in tabs if t[0] == tab)
        body = self.target(draw.split(":", 1)[1]) if draw.startswith("target:") else getattr(self, draw)(hosts, view)
        note = f"<div class=flash>{e(flash)}</div>" if flash else ""
        return self.band(key, tab) + note + body


def first(view):
    key, (_, _, tabs) = next(iter(VIEWS[view][1].items()))
    return f"/{key}/{tabs[0][0]}"


CSRF_KEY = secrets.token_bytes(32)
LOCK = threading.Lock()
TARGET_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,30}")
KEEP = re.compile(r"(\d{1,4}[hdwmy])( \d{1,4}[hdwmy]){0,5}")
HOST = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}")
USER = re.compile(r"[a-z_][a-z0-9_-]{0,31}")
REPOSITORY = re.compile(r"[A-Za-z0-9][A-Za-z0-9:/._@+-]{0,250}")


def save_targets(targets):
    new = DUMP_DIR / "targets.json.new"
    new.write_text(json.dumps(targets, indent=1))
    os.chmod(new, 0o644)
    new.replace(DUMP_DIR / "targets.json")


def apply_change(path, form):
    """An admin's change to the target list; returns (where to go, what to say)."""
    parts = path.strip("/").split("/")
    targets = dict(TARGETS)
    if parts == ["-", "dump", "add"]:
        name = form.get("name", "")
        if not TARGET_NAME.fullmatch(name) or name in targets:
            return "/dump/overview", "a name of lowercase letters, digits and dashes, not yet used"
        keep = form.get("keep") or "14d 8w 12m"
        if not KEEP.fullmatch(keep):
            return "/dump/overview", "keep reads like 14d 8w 12m"
        if form.get("kind") == "restic":
            if not REPOSITORY.fullmatch(form.get("repository", "")):
                return "/dump/overview", "a restic repository, such as rclone:gdrive:dump"
            targets[name] = {"kind": "restic", "repository": form["repository"], "keep": keep, "state": "active"}
        else:
            if not HOST.fullmatch(form.get("host", "")) or not USER.fullmatch(form.get("user") or "dump"):
                return "/dump/overview", "the machine's address, such as pc2.netbird, and its user"
            targets[name] = {"kind": "btrbk", "host": form["host"], "user": form.get("user") or "dump", "keep": keep, "state": "active"}
        save_targets(targets)
        return f"/dump/{name}", "added; nest looks at it within five minutes"
    if len(parts) == 4 and parts[:2] == ["-", "dump"] and parts[3] in targets:
        action, name = parts[2], parts[3]
        t = dict(targets[name])
        if action == "disk":
            # Only a blank disk nest saw on that machine, and only with its serial typed.
            seen = {d.get("id"): d for d in ((MANAGER.get("targets") or {}).get(name) or {}).get("disks") or []}
            disk = seen.get(form.get("disk"))
            if not disk or not disk.get("blank"):
                return f"/dump/{name}", "pick one of the blank disks nest found"
            if form.get("confirm", "").strip() != disk.get("serial"):
                return f"/dump/{name}", "the serial typed does not match that disk; nothing changes"
            t.update(disk=disk["id"], serial=disk["serial"], confirm=disk["serial"])
            msg = "confirmed; nest formats it within five minutes"
        elif action == "remove":
            t["state"] = "removed"
            if form.get("wipe"):
                t["wipe"] = form["wipe"].strip()
            msg = "removed; nest stops sending copies" + ("; it wipes the disk if that serial matches" if form.get("wipe") else "")
        elif action == "forget" and t.get("state") == "removed":
            del targets[name]
            save_targets(targets)
            return "/dump/overview", f"{name} is gone from the list"
        else:
            return "/dump/overview", "not possible"
        targets[name] = t
        save_targets(targets)
        return f"/dump/{name}", msg
    return "/dump/overview", "not possible"


class Handler(BaseHTTPRequestHandler):
    def who(self):
        # Caddy strips these from visitors; only the login proxy sets them.
        name = self.headers.get("X-Forwarded-Preferred-Username") or self.headers.get("X-Forwarded-User")
        admin = bool(name) and "admin" in self.headers.get("X-Forwarded-Groups", "").split(",")
        csrf = hmac.new(CSRF_KEY, (name or "").encode(), "sha256").hexdigest()
        return name, admin, csrf

    def do_GET(self):
        with LOCK:
            refresh()
            self.get()

    def do_POST(self):
        with LOCK:
            refresh()
            name, admin, csrf = self.who()
            length = min(int(self.headers.get("Content-Length", "0") or 0), 16384)
            form = {k: v[0].strip() for k, v in parse_qs(self.rfile.read(length).decode(errors="replace")).items()}
            if not admin or not hmac.compare_digest(form.get("csrf", ""), csrf):
                return self.redirect("/dump/overview?msg=" + quote("only status admins on id.bresilla.com may change targets"))
            try:
                to, msg = apply_change(urlparse(self.path).path, form)
            except OSError as err:
                to, msg = "/dump/overview", f"could not save: {err}"
            self.redirect(to + "?msg=" + quote(msg))

    def get(self):
        name, admin, csrf = self.who()
        url = urlparse(self.path)
        flash = parse_qs(url.query).get("msg", [""])[0]
        parts = [p for p in url.path.split("/") if p]
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
        body = Report(admin, csrf).render(key, parts[1], flash)
        self.reply(200, f"{labels[parts[1]]} · {title}", body, name, view, key)

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
