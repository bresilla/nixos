"""skill.bresilla.com: the skills repository as pages, read-only and open to everyone.

Reads a checkout of bresilla/skills and what the refresh writes beside it: the index
from `skillshare hub index --full --audit`, every finding from `skillshare audit
--format json`, and the repository's history. Serves /skillshare-hub.json for
`skillshare search --hub` and the same data as JSON under /api/.
"""

import html
import io
import json
import os
import re
import tarfile
import threading
from collections import Counter
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse

import markdown
import yaml

import site_ui

env = os.environ.get
STATE = Path(env("SKILL_STATE", "/var/lib/skill"))
REPO = Path(env("SKILL_REPO", str(STATE / "repo")))
INDEX = Path(env("SKILL_INDEX", str(STATE / "skillshare-hub.json")))
AUDIT = Path(env("SKILL_AUDIT", str(STATE / "audit.json")))
HISTORY = Path(env("SKILL_HISTORY", str(STATE / "history.txt")))
LISTEN = env("SKILL_LISTEN", "127.0.0.1:8094")
HOME = env("SKILL_HOME", "git.bresilla.com/bresilla/skills").rstrip("/")
DOMAIN = env("SKILL_DOMAIN", "skill.bresilla.com")
SITE = "skills"
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}")
RISK = {"clean": "ok", "low": "ok", "medium": "warn", "high": "fail", "critical": "fail"}
RISK_ORDER = ["clean", "low", "medium", "high", "critical"]
SEVERITY = {"INFO": "none", "LOW": "ok", "MEDIUM": "warn", "HIGH": "fail", "CRITICAL": "fail"}
SEVERITY_ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFO"]
TEXT = {".md", ".txt", ".yaml", ".yml", ".json", ".toml", ".lua", ".py", ".sh", ".js", ".ts", ".svg", ".nix", ".go", ".rs"}
LIMIT = 512 * 1024
LINKS = [("overview", "/", "Overview"), ("skills", "/skills", "Skills"), ("audit", "/audit", "Audit"),
         ("activity", "/activity", "Activity"), ("install", "/install", "Install")]

STYLE = site_ui.STYLE + """
.tile h3 svg { width: 16px; height: 16px; flex: none; }
.tile p.desc { margin: 0; color: var(--mute); font-size: var(--site-font-small);
  display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
.tile .meta { display: flex; gap: var(--s3); flex-wrap: wrap; font-size: var(--site-font-tiny); color: var(--mute); margin-top: auto; }
.tile .meta span { display: inline-flex; align-items: center; gap: 4px; }
.tile .meta svg { width: 12px; height: 12px; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: var(--s4); margin-bottom: var(--s5); }
.stat { border: 1px solid var(--line); border-radius: var(--site-radius-large); padding: var(--s4) var(--s5); background: var(--raised); min-width: 0; }
.stat .label { color: var(--mute); font-size: var(--site-font-tiny); text-transform: uppercase; letter-spacing: .06em; }
.stat .value { font-size: 26px; color: var(--accent-ink); margin-top: 4px; }
.stat .sub { color: var(--mute); font-size: var(--site-font-tiny); margin-top: 2px; }
.toolbar { display: flex; gap: var(--s3); flex-wrap: wrap; align-items: center; margin: 0 0 var(--s4); }
.toolbar input.search { flex: 1 1 260px; max-width: 420px; margin: 0; }
.chips { display: flex; gap: var(--s2); flex-wrap: wrap; }
.chip { border: 1px solid var(--line); border-radius: 999px; padding: 2px 12px; font-size: var(--site-font-tiny); cursor: pointer;
  background: var(--raised); color: var(--mute); user-select: none; }
.chip.on { border-color: var(--accent); color: var(--accent-ink); background: color-mix(in srgb, var(--accent) 14%, transparent); }
.toolbar select { height: 30px; }
.view-table .grid.cards { display: none; } .view-cards table.list { display: none; }
.split { display: flex; height: 10px; border-radius: 999px; overflow: hidden; background: var(--line); margin: var(--s2) 0; }
.split i { display: block; height: 100%; }
.split i.ok { background: var(--site-ok, #3a9a5b); } .split i.warn { background: var(--site-warn, #c8961e); }
.split i.fail { background: var(--site-fail, #c8463c); } .split i.none { background: var(--mute); }
.legend { display: flex; gap: var(--s4); flex-wrap: wrap; font-size: var(--site-font-tiny); color: var(--mute); }
.legend span { display: inline-flex; gap: 6px; align-items: center; }
.doc { max-width: 860px; line-height: 1.6; overflow-wrap: anywhere; }
.doc pre { overflow-x: auto; }
.doc pre code { background: none; padding: 0; border: 0; }
.viewswitch { display: flex; gap: var(--s3); margin: 0 0 var(--s3); font-size: var(--site-font-small); }
.viewswitch .on { color: var(--accent-ink); font-weight: bold; text-decoration: none; }
.doc table { margin: var(--s3) 0; }
.code { font-family: var(--site-code-font); font-size: var(--site-font-small); border: 1px solid var(--line); border-radius: var(--site-radius);
  overflow-x: auto; background: var(--raised); }
.code table { border: 0; margin: 0; width: 100%; border-collapse: collapse; }
.code td { border: 0; padding: 0 var(--s3); white-space: pre-wrap; overflow-wrap: anywhere; vertical-align: top; line-height: 1.55; }
header nav { min-width: 0; overflow-x: auto; scrollbar-width: none; }
header nav a { white-space: nowrap; }
.code td.n { color: var(--mute); text-align: right; user-select: none; width: 1%; border-right: 1px solid var(--line); }
.code td.n a { color: inherit; text-decoration: none; }
.code tr.hit td { background: color-mix(in srgb, var(--site-fail, #c8463c) 12%, transparent); }
.code tr:target td { background: color-mix(in srgb, var(--accent) 22%, transparent); }
.finding { border: 1px solid var(--line); border-radius: var(--site-radius); padding: var(--s3) var(--s4); margin: 0 0 var(--s3); background: var(--raised); }
.finding .top { display: flex; gap: var(--s3); align-items: center; flex-wrap: wrap; }
.finding .top .where { margin-left: auto; font-family: var(--site-code-font); font-size: var(--site-font-tiny); }
.finding blockquote { margin: var(--s2) 0 0; padding: var(--s2) var(--s3); border-left: 3px solid var(--line); color: var(--mute);
  font-family: var(--site-code-font); font-size: var(--site-font-tiny); white-space: pre-wrap; overflow-wrap: anywhere; }
.commit { display: grid; grid-template-columns: auto 1fr auto; gap: 2px var(--s4); padding: var(--s3) 0; border-bottom: 1px solid var(--line); }
.commit:last-child { border-bottom: 0; }
.commit code { color: var(--mute); font-size: var(--site-font-tiny); background: none; padding: 0; }
.commit .when { color: var(--mute); font-size: var(--site-font-tiny); white-space: nowrap; }
.commit .touched { grid-column: 2 / 4; display: flex; gap: var(--s2); flex-wrap: wrap; }
.tag { font-size: var(--site-font-tiny); border: 1px solid var(--line); border-radius: 999px; padding: 0 8px; color: var(--mute); text-decoration: none; }
a.tag:hover { border-color: var(--accent); color: var(--accent-ink); }
.tree a { font-family: var(--site-code-font); font-size: var(--site-font-small); }
.tree .dir { color: var(--mute); font-family: var(--site-code-font); font-size: var(--site-font-small); }
td.dir svg, .legend svg, .finding svg { width: 14px; height: 14px; vertical-align: -2px; }
.kv { display: grid; grid-template-columns: max-content 1fr; gap: 4px var(--s5); font-size: var(--site-font-small); }
.kv dt { color: var(--mute); } .kv dd { margin: 0; overflow-wrap: anywhere; }
.steps { counter-reset: step; display: grid; gap: var(--s4); }
.steps > div { counter-increment: step; }
.steps h4::before { content: counter(step) ". "; color: var(--accent-ink); }
.steps h4 { margin: 0 0 var(--s2); font-weight: normal; }
.cols { display: grid; grid-template-columns: minmax(0, 2fr) minmax(260px, 1fr); gap: var(--s5); align-items: start; }
@media (max-width: 900px) { .cols { grid-template-columns: 1fr; } }
@media (max-width: 720px) { section.set > div:has(> table) { overflow-x: auto; } .commit { grid-template-columns: 1fr; } .commit .touched { grid-column: 1; } }
"""

SCRIPT = site_ui.SCRIPT + """
document.addEventListener("click", (event) => {
  const id = event.target.dataset?.copy;
  if (!id) return;
  const button = event.target;
  navigator.clipboard?.writeText(document.getElementById(id).textContent).then(() => {
    button.classList.add("done");
    setTimeout(() => button.classList.remove("done"), 1200);
  }, () => getSelection().selectAllChildren(document.getElementById(id)));
});
function skillFilter() {
  const box = document.querySelector("[data-browser]");
  if (!box) return;
  const words = (box.querySelector("input.search")?.value || "").toLowerCase().split(/\\s+/).filter(Boolean);
  const risks = [...box.querySelectorAll(".chip.on[data-risk]")].map((c) => c.dataset.risk);
  const origins = [...box.querySelectorAll(".chip.on[data-origin]")].map((c) => c.dataset.origin);
  let shown = 0;
  for (const item of box.querySelectorAll("[data-find]")) {
    const ok = words.every((w) => item.dataset.find.includes(w))
      && (!risks.length || risks.includes(item.dataset.riskLabel))
      && (!origins.length || origins.includes(item.dataset.origin));
    item.hidden = !ok;
    if (ok && item.matches(".tile")) shown++;
  }
  const count = box.querySelector(".shown");
  if (count) count.textContent = shown;
}
function skillSort(key) {
  const box = document.querySelector("[data-browser]");
  for (const list of box.querySelectorAll("[data-sortable]")) {
    const items = [...list.querySelectorAll(":scope > [data-find]")];
    items.sort((a, b) => key === "name" ? a.dataset.name.localeCompare(b.dataset.name)
      : (Number(b.dataset[key]) - Number(a.dataset[key])) || a.dataset.name.localeCompare(b.dataset.name));
    items.forEach((item) => list.appendChild(item));
  }
}
document.addEventListener("input", (event) => { if (event.target.matches("[data-browser] input.search")) skillFilter(); });
document.addEventListener("click", (event) => {
  const chip = event.target.closest("[data-browser] .chip");
  if (chip) { chip.classList.toggle("on"); skillFilter(); }
  const view = event.target.closest("[data-view]");
  if (view) {
    const box = document.querySelector("[data-browser]");
    box.classList.toggle("view-table", view.dataset.view === "table");
    box.classList.toggle("view-cards", view.dataset.view !== "table");
    try { localStorage.setItem("skill-view", view.dataset.view); } catch (e) {}
  }
});
document.addEventListener("change", (event) => { if (event.target.matches("[data-browser] select.sort")) skillSort(event.target.value); });
document.addEventListener("DOMContentLoaded", () => {
  const box = document.querySelector("[data-browser]");
  if (!box) return;
  let view = "cards";
  try { view = localStorage.getItem("skill-view") || "cards"; } catch (e) {}
  box.classList.add(view === "table" ? "view-table" : "view-cards");
  const q = new URLSearchParams(location.search).get("q");
  if (q) { box.querySelector("input.search").value = q; }
  skillFilter();
});
"""

e = html.escape
_cache = {"key": None}
_lock = threading.Lock()


# --- Reading the repository, the index, the audit and the history ----------------------------

def frontmatter(text):
    if not text.startswith("---"):
        return {}, text
    parts = text.split("\n---", 1)
    if len(parts) < 2:
        return {}, text
    try:
        meta = yaml.safe_load(parts[0][3:]) or {}
    except yaml.YAMLError:
        meta = {}
    body = parts[1].split("\n", 1)[1] if "\n" in parts[1] else ""
    return (meta if isinstance(meta, dict) else {}), body


def files_of(folder):
    out = []
    for path in sorted(folder.rglob("*")):
        rel = path.relative_to(folder)
        if path.is_file() and not any(part.startswith(".") for part in rel.parts):
            out.append((str(rel), path.stat().st_size))
    return out


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def read_history():
    try:
        raw = HISTORY.read_text(errors="replace")
    except OSError:
        return []
    commits = []
    for record in raw.split("\x1e")[1:]:
        head, _, rest = record.partition("\n")
        fields = head.split("\x1f")
        if len(fields) < 4:
            continue
        paths = [line for line in rest.splitlines() if line.strip()]
        touched = sorted({p.split("/", 1)[0] for p in paths if "/" in p})
        commits.append({"hash": fields[0], "author": fields[1], "date": fields[2], "subject": fields[3],
                        "files": paths, "skills": touched})
    return commits


def tokens(text):
    return max(0, round(len(text) / 4))


def mtime(path):
    try:
        return path.stat().st_mtime_ns
    except OSError:
        return 0


def load():
    key = (mtime(INDEX), mtime(AUDIT), mtime(HISTORY), mtime(REPO / ".git" / "HEAD"), mtime(REPO / ".git" / "FETCH_HEAD"), mtime(REPO))
    with _lock:
        if key == _cache["key"]:
            return _cache["data"]
        index = read_json(INDEX)
        audit = read_json(AUDIT)
        history = read_history()
        indexed = {item.get("relPath") or item.get("name"): item for item in index.get("skills", [])}
        audited = {r.get("skillName"): r for r in audit.get("results", [])}
        skills = []
        for folder in sorted(REPO.iterdir()) if REPO.is_dir() else []:
            readme = folder / "SKILL.md"
            if not folder.is_dir() or folder.name.startswith(".") or not readme.is_file():
                continue
            text = readme.read_text(errors="replace")
            meta, body = frontmatter(text)
            item = indexed.get(folder.name, {})
            result = audited.get(folder.name, {})
            extra = meta.get("metadata") if isinstance(meta.get("metadata"), dict) else {}
            version = meta.get("version") or extra.get("version") or item.get("version")
            description = " ".join(str(meta.get("description") or item.get("description") or "").split())
            files = files_of(folder)
            commits = [c for c in history if folder.name in c["skills"]]
            findings = sorted(result.get("findings") or [],
                              key=lambda f: (SEVERITY_ORDER.index(f.get("severity", "INFO")) if f.get("severity") in SEVERITY_ORDER else 9,
                                             f.get("file", ""), f.get("line") or 0))
            risk = result.get("riskLabel") or item.get("riskLabel")
            skills.append({
                "name": folder.name,
                "title": str(meta.get("name") or folder.name),
                "description": description,
                "license": meta.get("license"),
                "compatibility": meta.get("compatibility"),
                "author": extra.get("author") or meta.get("author"),
                "version": str(version) if version else None,
                "manual": bool(meta.get("disable-model-invocation")),
                "meta": meta,
                "origin": item.get("repoUrl") or (item.get("source") if "/" in str(item.get("source", "")) else None),
                "type": item.get("type") or "local",
                "installed": item.get("installedAt"),
                "risk": risk,
                "score": result.get("riskScore", item.get("riskScore")),
                "audited": item.get("auditedAt") or index.get("generatedAt"),
                "findings": findings,
                "analyzability": result.get("analyzability"),
                "blocked": result.get("isBlocked"),
                "body": body,
                "files": files,
                "size": sum(n for _, n in files),
                "always": tokens(f"{meta.get('name') or folder.name}: {description}"),
                "demand": tokens(body),
                "commits": commits,
                "updated": commits[0]["date"] if commits else None,
            })
        data = {"skills": skills, "index": index, "audit": audit, "history": history}
        _cache.update(key=key, data=data)
        return data


def find(name):
    return next((s for s in load()["skills"] if s["name"] == name), None)


def hub_index():
    index = load()["index"]
    out = {k: v for k, v in index.items() if k != "sourcePath"}
    out["skills"] = [dict(item, source=f"{HOME}/{item.get('relPath') or item['name']}") for item in index.get("skills", [])]
    return out


def skill_json(s, full=False):
    keys = ["name", "title", "description", "license", "version", "author", "origin", "type", "installed", "risk", "score",
            "audited", "size", "always", "demand", "updated", "manual"]
    out = {k: s[k] for k in keys}
    out["files"] = [{"path": p, "size": n} for p, n in s["files"]]
    out["findings"] = len(s["findings"])
    out["install"] = f"skillshare install {HOME}/{s['name']}"
    if full:
        out["findings"] = s["findings"]
        out["frontmatter"] = json.loads(json.dumps(s["meta"], default=str))
        out["commits"] = [{k: c[k] for k in ("hash", "author", "date", "subject")} for c in s["commits"]]
    return out


# --- Turning Markdown into safe HTML -------------------------------------------------------------

def render(text, base=""):
    md = markdown.Markdown(extensions=["fenced_code", "tables", "sane_lists", "toc"])
    md.preprocessors.deregister("html_block")
    md.inlinePatterns.deregister("html")
    out = md.convert(text)
    out = re.sub(r'href="(?!https?:|#|/)([A-Za-z0-9_./-]+)"', lambda m: f'href="{base}{m[1]}"', out)
    return re.sub(r'href="(?!https?:|#|/)[^"]*"', 'href="#"', out)


# --- Small formatting helpers -------------------------------------------------------------------

def size(n):
    return f"{n} B" if n < 1024 else f"{n / 1024:.1f} KiB" if n < 1024 * 1024 else f"{n / 1048576:.1f} MiB"


def num(n):
    return f"{n / 1000:.1f}K" if n >= 1000 else str(n)


def ago(stamp):
    if not stamp:
        return "—"
    try:
        then = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return stamp[:10]
    seconds = (datetime.now(timezone.utc) - then).total_seconds()
    for unit, length in (("y", 31536000), ("mo", 2592000), ("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= length:
            return f"{int(seconds // length)}{unit} ago"
    return "just now"


def day(stamp):
    return (stamp or "")[:16].replace("T", " ")


def risk_pill(skill):
    label = skill.get("risk")
    return site_ui.pill(RISK.get(label, "warn"), label) if label else site_ui.pill("none", "not audited")


def sev_pill(severity):
    return site_ui.pill(SEVERITY.get(severity, "none"), (severity or "info").lower())


def command(block_id, text):
    return (f'<div class=cmd><button class=iconbtn title=copy data-copy={block_id}>{site_ui.ICONS["copy"]}</button>'
            f'<pre id={block_id}>{e(text)}</pre></div>')


def stat(label, value, sub=""):
    return f'<div class=stat><div class=label>{e(label)}</div><div class=value>{value}</div><div class=sub>{sub}</div></div>'


def split(parts):
    total = sum(n for _, n, _ in parts) or 1
    bar = "".join(f'<i class={state} style="width:{n / total * 100:.2f}%" title="{e(label)}: {n}"></i>' for label, n, state in parts if n)
    legend = "".join(f'<span>{site_ui.dot(state)}{e(label)} {n}</span>' for label, n, state in parts)
    return f'<div class=split>{bar}</div><div class=legend>{legend}</div>'


def origin_of(s):
    return "upstream" if s["origin"] else "own"


def commit_html(c, limit=None):
    names = c["skills"] + [p for p in c["files"] if "/" not in p]
    shown = names if limit is None else names[:limit]
    touched = "".join(f'<a class=tag href="/{quote(n)}">{e(n)}</a>' if n in c["skills"] else f'<span class=tag>{e(n)}</span>'
                      for n in shown)
    if len(shown) < len(names):
        touched += f'<span class="tag mute">+{len(names) - len(shown)}</span>'
    commit_url = f"https://{HOME}/commit/{c['hash']}"
    return (f'<div class=commit><code><a href="{e(commit_url)}" rel="noopener noreferrer">{e(c["hash"][:7])}</a></code>'
            f'<div>{e(c["subject"])} <span class=mute>· {e(c["author"])}</span></div>'
            f'<div class=when title="{e(day(c["date"]))}">{e(ago(c["date"]))}</div>'
            f'<div class=touched>{touched}</div></div>')


def page(title, body, active):
    return site_ui.page(site=SITE, title=title, body=body, links=LINKS, active=active, style=STYLE, script=SCRIPT, sign_in=False)


# --- Pages ---------------------------------------------------------------------------------------

def skill_card(s):
    find_text = e(f"{s['name']} {s['title']} {s['description']} {s['author'] or ''}".lower())
    meta = (f'<span>{site_ui.icon("paths")}{len(s["files"])} files</span>'
            f'<span title="always loaded / on demand">{site_ui.icon("cpu")}~{num(s["always"])} · {num(s["demand"])} tok</span>'
            + (f'<span>{site_ui.icon("pin")}{e(s["version"])}</span>' if s["version"] else "")
            + (f'<span>{site_ui.icon("globe")}upstream</span>' if s["origin"] else f'<span>{site_ui.icon("user")}own</span>')
            + (f'<span>{site_ui.icon("history")}{e(ago(s["updated"]))}</span>' if s["updated"] else ""))
    return (f'<a class=tile href="/{quote(s["name"])}" data-find="{find_text}" data-name="{e(s["name"])}" '
            f'data-risk-label="{e(s["risk"] or "")}" data-origin="{origin_of(s)}" data-size="{s["size"]}" '
            f'data-score="{s["score"] or 0}" data-demand="{s["demand"]}" data-updated="{e((s["updated"] or "")[:19].replace("-", "").replace(":", "").replace("T", ""))}">'
            f'<h3>{site_ui.icon("box")}{e(s["name"])}{risk_pill(s)}</h3>'
            f'<p class=desc>{e(s["description"]) or "<span class=mute>no description</span>"}</p>'
            f'<div class=meta>{meta}</div></a>')


def skill_row(s):
    find_text = e(f"{s['name']} {s['title']} {s['description']} {s['author'] or ''}".lower())
    return (f'<tr data-find="{find_text}" data-name="{e(s["name"])}" data-risk-label="{e(s["risk"] or "")}" '
            f'data-origin="{origin_of(s)}" data-size="{s["size"]}" data-score="{s["score"] or 0}" data-demand="{s["demand"]}" '
            f'data-updated="{e((s["updated"] or "")[:19].replace("-", "").replace(":", "").replace("T", ""))}">'
            f'<td><a href="/{quote(s["name"])}">{e(s["name"])}</a></td><td>{risk_pill(s)}</td>'
            f'<td class=num>{len(s["findings"])}</td><td>{origin_of(s)}</td><td>{e(s["version"] or "—")}</td>'
            f'<td class=num>{len(s["files"])}</td><td class=num>{size(s["size"])}</td>'
            f'<td class=num>{num(s["demand"])}</td><td>{e(ago(s["updated"]))}</td></tr>')


def browser(skills, compact=False):
    risks = Counter(s["risk"] for s in skills)
    chips = "".join(f'<span class=chip data-risk="{r}">{r} {risks[r]}</span>' for r in RISK_ORDER if risks[r])
    origins = Counter(origin_of(s) for s in skills)
    chips += "".join(f'<span class=chip data-origin="{o}">{o} {origins[o]}</span>' for o in ("own", "upstream") if origins[o])
    sort = ('<select class=sort aria-label="Sort"><option value=name>name</option><option value=updated>recently changed</option>'
            '<option value=score>risk score</option><option value=demand>largest</option></select>')
    views = (f'<button class="iconbtn" data-view=cards title="cards">{site_ui.icon("overview")}</button>'
             f'<button class="iconbtn" data-view=table title="table">{site_ui.icon("database")}</button>')
    toolbar = (f'<div class=toolbar><input class=search type=search placeholder="Filter skills" aria-label="Filter skills">'
               f'<div class=chips>{chips}</div>{"" if compact else sort}{"" if compact else views}'
               f'<span class=mute><span class=shown>{len(skills)}</span> of {len(skills)}</span></div>')
    cards = f'<div class="grid cards" data-sortable>{"".join(skill_card(s) for s in skills)}</div>'
    head = "<tr><th>skill</th><th>audit</th><th class=num>findings</th><th>from</th><th>version</th><th class=num>files</th><th class=num>size</th><th class=num>tokens</th><th>changed</th></tr>"
    table = f'<table class=list><thead>{head}</thead><tbody data-sortable>{"".join(skill_row(s) for s in skills)}</tbody></table>'
    if not skills:
        return '<div class=empty>no skills yet</div>'
    return f'<div data-browser>{toolbar}{cards}{"" if compact else table}</div>'


def overview():
    data = load()
    skills, history, audit = data["skills"], data["history"], data["audit"]
    risks = Counter(s["risk"] or "not audited" for s in skills)
    findings = sum(len(s["findings"]) for s in skills)
    always = sum(s["always"] for s in skills)
    demand = sum(s["demand"] for s in skills)
    files = sum(len(s["files"]) for s in skills)
    total = sum(s["size"] for s in skills)
    upstream = sum(1 for s in skills if s["origin"])
    last = history[0] if history else None
    worst = max((s["risk"] for s in skills if s["risk"]), key=RISK_ORDER.index, default=None)
    stats = (stat("Skills", len(skills), f"{len(skills) - upstream} own · {upstream} upstream")
             + stat("Files", files, size(total))
             + stat("Always loaded", f"~{num(always)}", "tokens, names and descriptions")
             + stat("On demand", f"~{num(demand)}", "tokens, every SKILL.md body")
             + stat("Findings", findings, f"worst: {worst}" if worst else "nothing audited yet")
             + stat("Last change", e(ago(last["date"])) if last else "—", e(last["subject"][:40]) if last else ""))
    parts = [(r, risks[r], RISK.get(r, "none")) for r in RISK_ORDER + ["not audited"] if risks[r]]
    sev = Counter(f.get("severity") for s in skills for f in s["findings"])
    sev_parts = [(name.lower(), sev[name], SEVERITY[name]) for name in SEVERITY_ORDER if sev[name]]
    categories = (audit.get("summary") or {}).get("byCategory") or {}
    cat_rows = "".join(f'<tr><td>{e(k)}</td><td class=num>{v}</td></tr>' for k, v in sorted(categories.items(), key=lambda kv: -kv[1]))
    audit_body = (f'<p class=mute>Skills by risk</p>{split(parts)}'
                  + (f'<p class=mute style="margin-top:var(--s4)">Findings by severity</p>{split(sev_parts)}' if sev_parts else "")
                  + (f'<table style="margin-top:var(--s4)"><tr><th>category</th><th class=num>findings</th></tr>{cat_rows}</table>' if cat_rows else "")
                  + '<p><a href="/audit">Every finding →</a></p>')
    activity = "".join(commit_html(c, limit=4) for c in history[:6]) or '<div class=empty>no history yet</div>'
    when = day(data["index"].get("generatedAt"))
    body = site_ui.band("Skills", "box", summary=f'{len(skills)} skills' + (f' · audited {e(when)} UTC' if when else ""))
    body += f'<div class=stats>{stats}</div>'
    body += f'<div class=cols><div>{site_ui.section("Skills", browser(skills, compact=True))}</div>'
    recent = activity + '<p><a href="/activity">All activity →</a></p>'
    body += f'<div>{site_ui.section("Audit", audit_body)}{site_ui.section("Recent changes", recent)}</div></div>'
    body += site_ui.section("Every skill on a machine", command("all", f"skillshare init --remote https://{HOME}.git\nskillshare pull"))
    return page("Skills", body, "overview")


def skills_page():
    skills = load()["skills"]
    body = site_ui.band("Skills", "box", crumbs=[("/", "overview")], summary=f"{len(skills)} skills")
    return page("skills", body + browser(skills), "skills")


def finding_html(f, skill=None, owner=True):
    where = f'{e(f.get("file", ""))}{":" + str(f["line"]) if f.get("line") else ""}'
    if skill and f.get("file"):
        link = f'/{quote(skill)}/{quote(f["file"])}' + (f'?view=source#L{f["line"]}' if f.get("line") else "")
        where = f'<a href="{e(link)}">{where}</a>'
    owner = f'<a class=tag href="/{quote(skill)}?tab=audit">{e(skill)}</a>' if skill and owner else ""
    snippet = f'<blockquote>{e(f["snippet"])}</blockquote>' if f.get("snippet") else ""
    rule = " · ".join(e(str(x)) for x in (f.get("ruleId"), f.get("category"), f.get("analyzer")) if x)
    confidence = f' · {f["confidence"]:.0%} sure' if isinstance(f.get("confidence"), (int, float)) else ""
    return (f'<div class=finding><div class=top>{sev_pill(f.get("severity"))}<b>{e(f.get("message", ""))}</b>{owner}'
            f'<span class=where>{where}</span></div><div class=mute style="font-size:var(--site-font-tiny)">{rule}{confidence}</div>{snippet}</div>')


def audit_page():
    data = load()
    skills = data["skills"]
    summary = data["audit"].get("summary") or {}
    sev = Counter(f.get("severity") for s in skills for f in s["findings"])
    stats = "".join(stat(name.lower(), sev[name]) for name in SEVERITY_ORDER)
    stats += stat("threshold", e(str(summary.get("threshold", "—")).lower()), "blocks installs at or above")
    rows = "".join(f'<tr><td><a href="/{quote(s["name"])}?tab=audit">{e(s["name"])}</a></td><td>{risk_pill(s)}</td>'
                   f'<td class=num>{s["score"] if s["score"] is not None else "—"}</td><td class=num>{len(s["findings"])}</td>'
                   f'<td class=num>{"—" if s["analyzability"] is None else f"{s["analyzability"]:.0%}"}</td>'
                   f'<td>{site_ui.pill("fail", "blocked") if s["blocked"] else site_ui.pill("ok", "passes")}</td></tr>'
                   for s in sorted(skills, key=lambda s: -(s["score"] or 0)))
    table = f'<table><tr><th>skill</th><th>risk</th><th class=num>score</th><th class=num>findings</th><th class=num>analyzable</th><th>install</th></tr>{rows}</table>'
    every = "".join(finding_html(f, s["name"]) for name in SEVERITY_ORDER for s in skills for f in s["findings"] if f.get("severity") == name)
    when = day(data["index"].get("generatedAt"))
    body = site_ui.band("Audit", "check", crumbs=[("/", "overview")],
                        summary=f'skillshare audit · {e(str(summary.get("mode", "global")))} profile' + (f' · {e(when)} UTC' if when else ""))
    body += f'<div class=stats>{stats}</div>'
    body += site_ui.section("Skills", table)
    body += site_ui.section("Findings", every or '<div class=empty>no findings</div>', note=f"{sum(sev.values())} in all")
    body += '<p class=mute>Static analysis by skillshare: patterns, data flow, structure and integrity. It does not run the skills.</p>'
    return page("audit", body, "audit")


def activity_page():
    history = load()["history"]
    body = site_ui.band("Activity", "history", crumbs=[("/", "overview")], summary=f"{len(history)} commits")
    body += site_ui.section("Commits", "".join(commit_html(c) for c in history) or '<div class=empty>no history yet</div>')
    return page("activity", body, "activity")


def install_page():
    hub = f"https://{DOMAIN}/skillshare-hub.json"
    config = (f"hub:\n  default: bresilla\n  hubs:\n    - label: bresilla\n      url: {hub}\n"
              f"gitea_hosts:\n  - {HOME.split('/')[0]}\n")
    steps = (f'<div><h4>Install skillshare</h4>{command("s1", "curl -fsSL https://raw.githubusercontent.com/runkids/skillshare/main/install.sh | sh")}'
             '<p class=mute>Or <code>nix profile add github:runkids/skillshare</code>; bresilla machines already have it.</p></div>'
             f'<div><h4>Take every skill from here</h4>{command("s2", f"skillshare init --remote https://{HOME}.git")}'
             '<p class=mute>The skills folder becomes a clone of this repository.</p></div>'
             f'<div><h4>Pull and link them into every agent</h4>{command("s3", "skillshare pull")}'
             '<p class=mute>Claude Code, Codex, OpenCode, Pi and the rest skillshare detects. Run it again for updates.</p></div>'
             f'<div><h4>Or search and pick single skills</h4>{command("s4", f"skillshare hub add {hub} --label bresilla" + chr(10) + "skillshare search --hub bresilla")}</div>')
    api = "".join(f'<tr><td><a href="{p}"><code>{p}</code></a></td><td>{e(d)}</td></tr>' for p, d in (
        ("/skillshare-hub.json", "the hub index, for skillshare search"),
        ("/api/skills", "every skill, with audit and size"),
        ("/api/skills/caveman", "one skill: frontmatter, findings, history"),
        ("/api/audit", "skillshare's audit report as JSON"),
        ("/api/activity", "the repository's commits"),
    ))
    body = site_ui.band("Install", "pull", crumbs=[("/", "overview")], summary="skillshare, pointed at this repository")
    body += site_ui.section("Get started", f'<div class=steps>{steps}</div>')
    body += site_ui.section("In ~/.config/skillshare/config.yaml", command("cfg", config))
    body += site_ui.section("Read-only API", f'<table><tr><th>path</th><th>what</th></tr>{api}</table>')
    body += site_ui.section("Source", f'<p><a href="https://{e(HOME)}">{e(HOME)}</a> · changes go in with <code>skillshare push</code> or a pull request.</p>')
    return page("install", body, "install")


def tree(s):
    out, seen = "", set()
    for path, n in s["files"]:
        parts = path.split("/")
        for depth in range(1, len(parts)):
            folder = "/".join(parts[:depth])
            if folder not in seen:
                seen.add(folder)
                out += f'<tr><td class=dir style="padding-left:{(depth - 1) * 18 + 8}px">{site_ui.icon("folder")} {e(parts[depth - 1])}/</td><td></td><td></td></tr>'
        hits = sum(1 for f in s["findings"] if f.get("file") == path)
        mark = site_ui.pill("warn", f"{hits} finding{'s' if hits > 1 else ''}") if hits else ""
        out += (f'<tr><td class=tree style="padding-left:{(len(parts) - 1) * 18 + 8}px"><a href="/{quote(s["name"])}/{quote(path)}">{e(parts[-1])}</a></td>'
                f'<td>{mark}</td><td class=num>{size(n)}</td></tr>')
    return f'<table><tr><th>file</th><th></th><th class=num>size</th></tr>{out}</table>'


def skill_page(s, tab):
    name = quote(s["name"])
    tabs = [(f"/{name}", "Overview", "overview", None, None, tab == "overview"),
            (f"/{name}?tab=files", "Files", "paths", len(s["files"]), None, tab == "files"),
            (f"/{name}?tab=audit", "Audit", "check", len(s["findings"]), RISK.get(s["risk"] or "", None), tab == "audit"),
            (f"/{name}?tab=history", "History", "history", len(s["commits"]), None, tab == "history")]
    text = s["description"]
    short = text if len(text) <= 240 else text[:240].rsplit(" ", 1)[0] + "…"
    body = site_ui.band(s["name"], "box", crumbs=[("/", "overview"), ("/skills", "skills")], summary=e(short),
                        items=tabs, small=s["version"] or "")
    if tab == "files":
        body += site_ui.section("Files", tree(s) + f'<p><a href="/{name}.tar.gz">Download all as .tar.gz</a></p>', note=size(s["size"]))
    elif tab == "audit":
        facts = (f'<dl class=kv><dt>risk</dt><dd>{risk_pill(s)} {s["score"] if s["score"] is not None else ""}/100</dd>'
                 f'<dt>install</dt><dd>{"blocked at the threshold" if s["blocked"] else "passes the threshold"}</dd>'
                 f'<dt>analyzable</dt><dd>{"—" if s["analyzability"] is None else f"{s["analyzability"]:.0%} of its text"}</dd>'
                 f'<dt>audited</dt><dd>{e(day(s["audited"]))} UTC</dd></dl>')
        body += site_ui.section("Result", facts)
        body += site_ui.section("Findings", "".join(finding_html(f, s["name"], owner=False) for f in s["findings"])
                                or '<div class=empty>no findings</div>')
    elif tab == "history":
        body += site_ui.section("Commits", "".join(commit_html(c) for c in s["commits"]) or '<div class=empty>no history yet</div>')
    else:
        facts = [("audit", f'{risk_pill(s)}' + (f' <span class=mute>{s["score"]}/100</span>' if s["score"] is not None else ""))]
        if s["version"]:
            facts.append(("version", e(s["version"])))
        if s["author"]:
            facts.append(("author", e(str(s["author"]))))
        if s["license"]:
            facts.append(("license", e(str(s["license"]))))
        if s["compatibility"]:
            facts.append(("works with", e(str(s["compatibility"]))))
        origin = s["origin"]
        if origin:
            link = origin if origin.startswith("http") else f"https://{origin}"
            facts.append(("from", f'<a href="{e(link)}" rel="noopener noreferrer">{e(origin.removeprefix("https://"))}</a>'))
            facts.append(("kind", e(s["type"])))
        else:
            facts.append(("from", "written here"))
        facts.append(("invoked", "only by hand" if s["manual"] else "by the model, when relevant"))
        facts.append(("tokens", f'~{num(s["always"])} always · ~{num(s["demand"])} on use'))
        facts.append(("files", f'{len(s["files"])} · {size(s["size"])}'))
        if s["updated"]:
            facts.append(("changed", f'<span title="{e(day(s["updated"]))}">{e(ago(s["updated"]))}</span>'))
        side = site_ui.tile("About", facts)
        side += site_ui.section("Install alone", command("one", f"skillshare install {HOME}/{s['name']}"))
        side += site_ui.section("Download", f'<p><a href="/{name}.tar.gz">{e(s["name"])}.tar.gz</a> · <a href="/{name}/SKILL.md">SKILL.md</a> · <a href="/api/skills/{name}">JSON</a></p>')
        fm = "".join(f'<dt>{e(str(k))}</dt><dd>{e(v if isinstance(v, str) else json.dumps(v, default=str))}</dd>'
                     for k, v in s["meta"].items() if k != "description")
        main_col = site_ui.section("SKILL.md", f'<div class=doc>{render(s["body"], f"/{name}/")}</div>')
        if fm:
            side += site_ui.section("Frontmatter", f'<dl class=kv>{fm}</dl>')
        body += f'<div class=cols><div>{main_col}</div><div>{side}</div></div>'
    return page(s["name"], body, "skills")


def file_page(s, rel, view="auto"):
    root = (REPO / s["name"]).resolve()
    path = (root / rel).resolve()
    if root not in path.parents or not path.is_file() or any(p.startswith(".") for p in Path(rel).parts):
        return None
    name = quote(s["name"])
    crumbs = [("/", "overview"), ("/skills", "skills"), (f"/{name}", s["name"]), (f"/{name}?tab=files", "files")]
    hits = {f.get("line"): f for f in s["findings"] if f.get("file") == rel and f.get("line")}
    body = site_ui.band(rel, "paths", crumbs=crumbs,
                        summary=f'{size(path.stat().st_size)}' + (f' · {len(hits)} finding{"s" if len(hits) > 1 else ""}' if hits else ""))
    if path.suffix.lower() not in TEXT or path.stat().st_size > LIMIT:
        return page(rel, body + f'<div class=empty>not shown here; it is in <a href="/{name}.tar.gz">the .tar.gz</a></div>', "skills")
    text = path.read_text(errors="replace")
    rows = ""
    for i, line in enumerate(text.splitlines(), 1):
        mark = f' class=hit title="{e(hits[i].get("message", ""))}"' if i in hits else ""
        rows += f'<tr id=L{i}{mark}><td class=n><a href="#L{i}">{i}</a></td><td>{e(line)}</td></tr>'
    here = f"/{name}/{quote(rel)}"
    rendered = path.suffix.lower() == ".md" and view != "source"
    switch = ""
    if path.suffix.lower() == ".md":
        switch = (f'<div class=viewswitch><a href="{here}" class="{"on" if rendered else ""}">rendered</a>'
                  f'<a href="{here}?view=source" class="{"" if rendered else "on"}">source</a>'
                  f'<a href="{here}?raw=1">raw</a></div>')
    else:
        switch = f'<div class=viewswitch><a href="{here}?raw=1">raw</a></div>'
    if rendered:
        folder = str(Path(rel).parent)
        base = f"/{name}/" + ("" if folder == "." else f"{quote(folder)}/")
        content = switch + f'<div class=doc>{render(frontmatter(text)[1], base)}</div>'
    else:
        content = switch + f'<div class=code><table>{rows}</table></div>'
    findings = "".join(finding_html(f, s["name"], owner=False) for f in s["findings"] if f.get("file") == rel)
    body += site_ui.section(rel, content)
    if findings:
        body += site_ui.section("Findings in this file", findings)
    return page(rel, body, "skills")


def tarball(s):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as tar:
        for rel, _ in s["files"]:
            tar.add(REPO / s["name"] / rel, arcname=f"{s['name']}/{rel}")
    return out.getvalue()


# --- The server ----------------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "skill"

    def reply(self, code, body, kind="text/html; charset=utf-8", headers=()):
        body = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        for header in headers:
            self.send_header(*header)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json(self, value):
        self.reply(200, json.dumps(value, indent=2, default=str), "application/json", [("Access-Control-Allow-Origin", "*")])

    def missing(self):
        self.reply(404, page("not found", site_ui.band("Not found", "x", crumbs=[("/", "overview")])
                             + '<div class=empty>no such skill or file</div>', ""))

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urlparse(self.path)
        path = unquote(url.path)
        query = parse_qs(url.query)
        routes = {"/": overview, "": overview, "/skills": skills_page, "/audit": audit_page,
                  "/activity": activity_page, "/install": install_page}
        if path in routes:
            return self.reply(200, routes[path]())
        if path == "/healthz":
            return self.reply(200, "ok\n", "text/plain")
        if path == "/skillshare-hub.json":
            return self.json(hub_index())
        if path == "/api/skills":
            return self.json([skill_json(s) for s in load()["skills"]])
        if path.startswith("/api/skills/"):
            s = find(path.removeprefix("/api/skills/"))
            return self.json(skill_json(s, full=True)) if s else self.missing()
        if path == "/api/audit":
            return self.json(load()["audit"])
        if path == "/api/activity":
            return self.json(load()["history"])
        parts = path.strip("/").split("/", 1)
        name = parts[0].removesuffix(".tar.gz")
        s = find(name) if NAME.fullmatch(name) else None
        if not s:
            return self.missing()
        if parts[0].endswith(".tar.gz") and len(parts) == 1:
            return self.reply(200, tarball(s), "application/gzip",
                              [("Content-Disposition", f'attachment; filename="{s["name"]}.tar.gz"')])
        if len(parts) == 1:
            tab = (query.get("tab") or ["overview"])[0]
            return self.reply(200, skill_page(s, tab if tab in ("files", "audit", "history") else "overview"))
        if query.get("raw"):
            root = (REPO / s["name"]).resolve()
            target = (root / parts[1]).resolve()
            if root in target.parents and target.is_file() and not any(p.startswith(".") for p in Path(parts[1]).parts):
                return self.reply(200, target.read_bytes(), "text/plain; charset=utf-8")
            return self.missing()
        result = file_page(s, parts[1], (query.get("view") or ["auto"])[0])
        return self.reply(200, result) if result else self.missing()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    host, port = LISTEN.rsplit(":", 1)
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()
