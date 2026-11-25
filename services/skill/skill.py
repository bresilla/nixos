"""skill.bresilla.com: the skills repository as pages, read-only and open to everyone.

Reads a checkout of bresilla/skills and the index `skillshare hub index --full --audit`
writes beside it. Serves /skillshare-hub.json for `skillshare search --hub`.
"""

import html
import io
import json
import os
import re
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlparse

import markdown
import yaml

import site_ui

env = os.environ.get
REPO = Path(env("SKILL_REPO", "/var/lib/skill/repo"))
INDEX = Path(env("SKILL_INDEX", "/var/lib/skill/skillshare-hub.json"))
LISTEN = env("SKILL_LISTEN", "127.0.0.1:8094")
HOME = env("SKILL_HOME", "git.bresilla.com/bresilla/skills").rstrip("/")
SITE = "skills"
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}")
RISK = {"clean": "ok", "low": "ok", "medium": "warn", "high": "fail", "critical": "fail"}
TEXT = {".md", ".txt", ".yaml", ".yml", ".json", ".toml", ".lua", ".py", ".sh", ".js", ".ts", ".svg", ".nix"}
LIMIT = 512 * 1024

STYLE = site_ui.STYLE + """
.search { width: 100%; max-width: 420px; margin: 0 0 var(--s4); }
.tile h3 svg { width: 16px; height: 16px; flex: none; }
.tile p.desc { margin: 0; color: var(--mute); font-size: var(--site-font-small);
  display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
.doc { max-width: 860px; line-height: 1.6; overflow-wrap: anywhere; }
.doc pre { overflow-x: auto; }
.doc table { margin: var(--s3) 0; }
.files a { font-family: var(--site-code-font); font-size: var(--site-font-small); }
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
document.addEventListener("input", (event) => {
  if (!event.target.matches("input.search")) return;
  const words = event.target.value.toLowerCase().split(/\\s+/).filter(Boolean);
  for (const tile of document.querySelectorAll(".grid .tile")) {
    const text = tile.dataset.find || "";
    tile.hidden = !words.every((word) => text.includes(word));
  }
});
"""

e = html.escape
_cache = {"key": None, "skills": [], "index": {}}
_lock = threading.Lock()


# --- Reading the repository and the index -------------------------------------------------

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


def load():
    try:
        key = (INDEX.stat().st_mtime_ns if INDEX.exists() else 0,
               (REPO / ".git" / "HEAD").stat().st_mtime_ns if (REPO / ".git").exists() else 0,
               REPO.stat().st_mtime_ns if REPO.exists() else 0)
    except OSError:
        key = None
    with _lock:
        if key is not None and key == _cache["key"]:
            return _cache["skills"], _cache["index"]
        try:
            index = json.loads(INDEX.read_text())
        except (OSError, ValueError):
            index = {}
        audited = {item.get("relPath") or item.get("name"): item for item in index.get("skills", [])}
        skills = []
        for folder in sorted(REPO.iterdir()) if REPO.is_dir() else []:
            readme = folder / "SKILL.md"
            if not folder.is_dir() or folder.name.startswith(".") or not readme.is_file():
                continue
            meta, body = frontmatter(readme.read_text(errors="replace"))
            item = audited.get(folder.name, {})
            extra = meta.get("metadata") if isinstance(meta.get("metadata"), dict) else {}
            version = meta.get("version") or extra.get("version") or item.get("version")
            skills.append({
                "name": folder.name,
                "title": str(meta.get("name") or folder.name),
                "description": " ".join(str(meta.get("description") or item.get("description") or "").split()),
                "license": meta.get("license"),
                "version": str(version) if version else None,
                "origin": item.get("repoUrl") or (item.get("source") if "/" in str(item.get("source", "")) else None),
                "risk": item.get("riskLabel"),
                "score": item.get("riskScore"),
                "audited": item.get("auditedAt"),
                "body": body,
                "files": files_of(folder),
            })
        _cache.update(key=key, skills=skills, index=index)
        return skills, index


def find(name):
    skills, _ = load()
    return next((s for s in skills if s["name"] == name), None)


def hub_index():
    _, index = load()
    out = dict(index)
    out.pop("sourcePath", None)
    items = []
    for item in index.get("skills", []):
        item = dict(item)
        item["source"] = f"{HOME}/{item.get('relPath') or item['name']}"
        items.append(item)
    out["skills"] = items
    return out


# --- Turning Markdown into safe HTML -------------------------------------------------------

def render(text):
    md = markdown.Markdown(extensions=["fenced_code", "tables", "sane_lists"])
    md.preprocessors.deregister("html_block")
    md.inlinePatterns.deregister("html")
    out = md.convert(text)
    return re.sub(r'href="(?!https?:|#|/|\.|[A-Za-z0-9_-]+[/.#]|[A-Za-z0-9_-]+")[^"]*"', 'href="#"', out)


# --- Page parts ------------------------------------------------------------------------------

def risk_pill(skill):
    label = skill.get("risk")
    if not label:
        return site_ui.pill("none", "not audited")
    return site_ui.pill(RISK.get(label, "warn"), label)


def command(block_id, text):
    return (f'<div class=cmd><button class=iconbtn title=copy data-copy={block_id}>{site_ui.ICONS["copy"]}</button>'
            f'<pre id={block_id}>{e(text)}</pre></div>')


def size(n):
    return f"{n} B" if n < 1024 else f"{n / 1024:.1f} KiB"


def overview():
    skills, index = load()
    tiles = ""
    for s in skills:
        find_text = e(f"{s['name']} {s['title']} {s['description']}".lower())
        foot = (f'<span class=mute>{e(s["version"])}</span>' if s["version"] else "")
        tiles += (f'<a class=tile href="/{quote(s["name"])}" data-find="{find_text}">'
                  f'<h3>{site_ui.icon("box")}{e(s["name"])}{risk_pill(s)}</h3>'
                  f'<p class=desc>{e(s["description"]) or "<span class=mute>no description</span>"}</p>'
                  f'{f"<div class=foot>{foot}</div>" if foot else ""}</a>')
    when = (index.get("generatedAt") or "")[:16].replace("T", " ")
    summary = f'{len(skills)} skills' + (f' · audited {e(when)} UTC' if when else "")
    body = site_ui.band("Skills", "box", summary=summary)
    body += '<input class=search type=search placeholder="Filter skills" aria-label="Filter skills" autofocus>'
    body += f'<div class=grid>{tiles}</div>' if tiles else '<div class=empty>no skills yet</div>'
    body += site_ui.section("Every skill on a machine", command("all", f"skillshare init --remote https://{HOME}.git\nskillshare pull"))
    body += site_ui.section("Search them from skillshare", command("hub", "skillshare hub add https://skill.bresilla.com/skillshare-hub.json --label bresilla\nskillshare search --hub bresilla"))
    return page("Skills", body)


def skill_page(s):
    crumbs = [("/", "skills")]
    facts = [("audit", f'{risk_pill(s)}' + (f' <span class=mute>{e(str(s["score"]))}/100</span>' if s["score"] is not None else ""))]
    if s["version"]:
        facts.append(("version", e(s["version"])))
    if s["license"]:
        facts.append(("license", e(str(s["license"]))))
    origin = s["origin"]
    if origin:
        link = origin if origin.startswith("http") else f"https://{origin}"
        facts.append(("from", f'<a href="{e(link)}" rel="noopener noreferrer">{e(origin.removeprefix("https://"))}</a>'))
    else:
        facts.append(("from", "written here"))
    files = "".join(f'<tr><td class=files><a href="/{quote(s["name"])}/{quote(path)}">{e(path)}</a></td><td class=num>{size(n)}</td></tr>'
                    for path, n in s["files"])
    text = s["description"]
    short = text if len(text) <= 240 else text[:240].rsplit(" ", 1)[0] + "…"
    body = site_ui.band(s["name"], "box", crumbs=crumbs, summary=e(short))
    body += f'<div class=grid>{site_ui.tile("About", facts)}</div>'
    body += site_ui.section("Install this skill alone", command("one", f"skillshare install {HOME}/{s['name']}"))
    body += site_ui.section("SKILL.md", f'<div class=doc>{render(s["body"])}</div>')
    body += site_ui.section("Files", f'<table><tr><th>file</th><th class=num>size</th></tr>{files}</table>'
                            f'<p><a href="/{quote(s["name"])}.tar.gz">Download all as .tar.gz</a></p>')
    return page(s["name"], body)


def file_page(s, rel):
    path = (REPO / s["name"] / rel).resolve()
    root = (REPO / s["name"]).resolve()
    if root not in path.parents or not path.is_file() or any(p.startswith(".") for p in Path(rel).parts):
        return None
    crumbs = [("/", "skills"), (f"/{quote(s['name'])}", s["name"])]
    body = site_ui.band(rel, "paths", crumbs=crumbs, summary=size(path.stat().st_size))
    if path.suffix.lower() not in TEXT or path.stat().st_size > LIMIT:
        return page(rel, body + '<div class=empty>not shown here; it is in the .tar.gz</div>')
    text = path.read_text(errors="replace")
    if path.suffix.lower() == ".md":
        content = f'<div class=doc>{render(frontmatter(text)[1])}</div>'
    else:
        content = f"<pre>{e(text)}</pre>"
    return page(rel, body + site_ui.section(rel, content))


def tarball(s):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as tar:
        for rel, _ in s["files"]:
            tar.add(REPO / s["name"] / rel, arcname=f"{s['name']}/{rel}")
    return out.getvalue()


def page(title, body):
    return site_ui.page(site=SITE, title=title, body=body, links=[("skills", "/", "Skills")], active="skills",
                        style=STYLE, script=SCRIPT, sign_in=False)


# --- The server ------------------------------------------------------------------------------

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

    def missing(self):
        self.reply(404, page("not found", site_ui.band("Not found", "x", crumbs=[("/", "skills")])
                             + '<div class=empty>no such skill or file</div>'))

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        if path == "/healthz":
            return self.reply(200, "ok\n", "text/plain")
        if path == "/skillshare-hub.json":
            return self.reply(200, json.dumps(hub_index(), indent=2), "application/json",
                              [("Access-Control-Allow-Origin", "*")])
        if path in ("/", ""):
            return self.reply(200, overview())
        parts = path.strip("/").split("/", 1)
        name = parts[0].removesuffix(".tar.gz")
        s = find(name) if NAME.fullmatch(name) else None
        if not s:
            return self.missing()
        if parts[0].endswith(".tar.gz") and len(parts) == 1:
            return self.reply(200, tarball(s), "application/gzip",
                              [("Content-Disposition", f'attachment; filename="{s["name"]}.tar.gz"')])
        if len(parts) == 1:
            return self.reply(200, skill_page(s))
        result = file_page(s, parts[1])
        return self.reply(200, result) if result else self.missing()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    host, port = LISTEN.rsplit(":", 1)
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()
