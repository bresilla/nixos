"""search.bresilla.com: web search through searx, drawn in the sites' own style.

searx (bresilla/searx) runs on loopback and answers in SearXNG's JSON; this page asks it,
draws the results, and signs image and favicon addresses for searx's own proxies, so the
browser only ever talks to this site. The login proxy in front puts the name in a header.
"""

import hashlib
import hmac
import html
import http.client
import json
import os
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlencode, urlparse

import site_ui

env = os.environ.get
LISTEN = env("SEARCH_LISTEN", "127.0.0.1:8096")
ENGINE = env("SEARCH_ENGINE", "127.0.0.1:8095")
DOMAIN = env("SEARCH_DOMAIN", "search.bresilla.com")
SECRET = Path(env("SEARCH_SECRET", "/var/lib/search/secret"))
SOURCE = "https://github.com/bresilla/searx"
SITE = "search"
CATEGORIES = [("general", "Web", "search"), ("images", "Images", "image"), ("videos", "Videos", "play"),
              ("news", "News", "news"), ("it", "IT", "code"), ("science", "Science", "book"),
              ("music", "Music", "music")]
KNOWN = {key for key, _, _ in CATEGORIES}
TIMES = [("", "Any time"), ("day", "Past day"), ("week", "Past week"), ("month", "Past month"), ("year", "Past year")]
LINKS = [("search", "/", "Search"), ("engines", "/engines", "Engines")]

STYLE = site_ui.STYLE + """
.home { min-height: 52vh; display: grid; place-content: center; gap: var(--s5); text-align: center; }
.home .mark { display: flex; gap: var(--s3); align-items: center; justify-content: center; font-size: 34px; color: var(--accent-ink); }
.home .mark svg { width: 40px; height: 40px; }
.home form.q { width: min(640px, 92vw); }
form.q { display: flex; gap: var(--s2); margin: 0; position: relative; }
form.q input[type=search] { flex: 1; margin: 0; height: 42px; font-size: 16px; padding: 0 var(--s4);
  border-radius: 999px; border: 1px solid var(--line-strong); background: var(--raised); color: var(--fg); min-width: 0; }
form.q input[type=search]:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 22%, transparent); }
form.q button { height: 42px; padding: 0 var(--s5); border-radius: 999px; display: inline-flex; align-items: center; }
form.q button svg { width: 18px; height: 18px; }
.suggest { position: absolute; top: 46px; left: 0; right: 0; z-index: 5; list-style: none; margin: 0; padding: var(--s1) 0;
  background: var(--raised); border: 1px solid var(--line-strong); border-radius: var(--site-radius-large); text-align: left; }
.suggest:empty { display: none; }
.suggest li { padding: var(--s1) var(--s4); cursor: pointer; }
.suggest li.on, .suggest li:hover { background: var(--hover); }
.hint { color: var(--mute); font-size: var(--site-font-tiny); }
.qbar { display: grid; gap: var(--s3); margin: var(--s5) 0 var(--s4); }
.qbar form.q { max-width: 720px; }
.filters { display: flex; gap: var(--s3); align-items: center; flex-wrap: wrap; font-size: var(--site-font-small); color: var(--mute); }
.filters a { color: var(--mute); text-decoration: none; }
.filters a.on { color: var(--accent-ink); font-weight: bold; }
.layout { display: grid; grid-template-columns: minmax(0, 720px) minmax(0, 320px); gap: var(--s7); align-items: start; }
.results { display: grid; gap: 0; }
.hit { display: grid; gap: 2px; min-width: 0; position: relative; padding: var(--s4) var(--s4); margin: 0 calc(var(--s4) * -1);
  border-radius: var(--site-radius);
  transition: background-color .22s ease, transform .22s cubic-bezier(.2, .7, .2, 1);
  animation: rise .42s cubic-bezier(.2, .7, .2, 1) both; animation-delay: calc(var(--i, 0) * 32ms); }
.hit + .hit::after { content: ""; position: absolute; top: 0; left: var(--s4); right: var(--s4);
  border-top: 1px dotted color-mix(in srgb, var(--accent) 38%, transparent); transition: opacity .22s ease; }
.hit::before { content: ""; position: absolute; left: 0; top: var(--s3); bottom: var(--s3); width: 2px; border-radius: 2px;
  background: var(--accent); transform: scaleY(0); transform-origin: center; transition: transform .26s cubic-bezier(.2, .7, .2, 1); }
.hit:hover, .hit.focus { background: color-mix(in srgb, var(--accent) 6%, transparent); transform: translateX(3px); }
.hit:hover::before, .hit.focus::before { transform: scaleY(1); }
.hit:hover::after, .hit.focus::after, .hit:hover + .hit::after, .hit.focus + .hit::after { opacity: 0; }
@keyframes rise { from { opacity: 0; transform: translateY(8px); } }
.hit .where { display: flex; gap: var(--s2); align-items: center; font-size: var(--site-font-tiny); color: var(--mute); min-width: 0; }
.hit .where img { width: 16px; height: 16px; border-radius: 3px; flex: none; transition: transform .3s cubic-bezier(.3, 1.6, .5, 1); }
.hit:hover .where img { transform: scale(1.18) rotate(-6deg); }
.hit .where span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hit h3 { margin: 0; font-size: 18px; font-weight: normal; line-height: 1.3; }
.hit h3 a { text-decoration: none; background: linear-gradient(currentColor, currentColor) 0 100% / 0 1px no-repeat;
  transition: background-size .32s cubic-bezier(.2, .7, .2, 1); padding-bottom: 1px; }
.hit:hover h3 a, .hit.focus h3 a { background-size: 100% 1px; }
.hit h3 a:visited { color: color-mix(in srgb, var(--accent-ink) 65%, var(--mute)); }
.hit p { margin: 2px 0 0; color: var(--fg); opacity: .86; overflow-wrap: anywhere; }
.hit .meta { display: flex; gap: var(--s2); flex-wrap: wrap; font-size: var(--site-font-tiny); color: var(--mute); margin-top: 2px; }
.hit .meta .eng { border: 1px solid var(--line); border-radius: 999px; padding: 0 8px; opacity: .55; transition: opacity .2s ease, border-color .2s ease; }
.hit:hover .meta .eng, .hit.focus .meta .eng { opacity: 1; border-color: var(--line-strong); }
.hit.media { grid-template-columns: 160px minmax(0, 1fr); gap: var(--s4); align-items: start; }
.hit.media .thumb { width: 160px; aspect-ratio: 16 / 9; object-fit: cover; border-radius: var(--site-radius); background: var(--panel);
  transition: transform .35s cubic-bezier(.2, .7, .2, 1), box-shadow .35s ease; }
.hit.media:hover .thumb { transform: scale(1.03); box-shadow: 0 6px 18px -10px color-mix(in srgb, var(--accent) 60%, transparent); }
.images { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: var(--s3); }
.images a { display: grid; gap: 4px; text-decoration: none; color: var(--mute); font-size: var(--site-font-tiny); min-width: 0;
  animation: rise .42s cubic-bezier(.2, .7, .2, 1) both; animation-delay: calc(var(--i, 0) * 18ms); transition: color .2s ease; }
.images a:hover { color: var(--fg); }
.images .frame { overflow: hidden; border-radius: var(--site-radius); border: 1px solid var(--line); background: var(--panel);
  transition: border-color .25s ease, transform .3s cubic-bezier(.2, .7, .2, 1), box-shadow .3s ease; }
.images a:hover .frame { border-color: var(--accent); transform: translateY(-3px);
  box-shadow: 0 10px 22px -14px color-mix(in srgb, var(--accent) 70%, transparent); }
.images img { width: 100%; height: 150px; object-fit: cover; display: block; transition: transform .5s cubic-bezier(.2, .7, .2, 1); }
.images a:hover img { transform: scale(1.06); }
.images span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.answer { border: 1px solid var(--line-strong); border-radius: var(--site-radius-large); padding: var(--s4) var(--s5);
  background: var(--panel); font-size: 17px; }
.did { color: var(--mute); }
aside { display: grid; gap: var(--s4); }
.infobox { border: 1px solid var(--line); border-radius: var(--site-radius-large); background: var(--raised); overflow: hidden; }
.infobox img { width: 100%; max-height: 220px; object-fit: contain; background: var(--panel); display: block; }
.infobox .body { padding: var(--s4) var(--s5); display: grid; gap: var(--s2); }
.infobox h3 { margin: 0; font-size: 18px; font-weight: normal; color: var(--accent-ink); }
.infobox p { margin: 0; font-size: var(--site-font-small); display: -webkit-box; -webkit-line-clamp: 7; -webkit-box-orient: vertical; overflow: hidden; }
.infobox dl { display: grid; grid-template-columns: minmax(80px, 38%) 1fr; gap: 2px var(--s3); margin: 0; font-size: var(--site-font-small); }
.infobox dt { color: var(--mute); }
.infobox dd { margin: 0; overflow-wrap: anywhere; }
.infobox .links { display: flex; gap: var(--s3); flex-wrap: wrap; font-size: var(--site-font-small); }
.related { display: grid; gap: var(--s1); font-size: var(--site-font-small); }
.pages { display: flex; gap: var(--s3); align-items: center; margin-top: var(--s6); }
.slow { color: var(--mute); font-size: var(--site-font-tiny); margin-top: var(--s5); }
.layout.wide { grid-template-columns: minmax(0, 1fr); }
form.q input[type=search] { transition: border-color .2s ease, box-shadow .25s ease, background-color .2s ease; }
form.q button { transition: transform .2s cubic-bezier(.3, 1.6, .5, 1), filter .2s ease; }
form.q button:hover { transform: scale(1.05); filter: brightness(1.08); }
form.q button:active { transform: scale(.96); }
form.q button svg { transition: transform .3s cubic-bezier(.3, 1.6, .5, 1); }
form.q button:hover svg { transform: rotate(-12deg) scale(1.1); }
.suggest:not(:empty) { animation: drop .18s ease-out both; transform-origin: top; }
.suggest li { transition: background-color .12s ease, padding-left .18s ease; }
.suggest li.on, .suggest li:hover { padding-left: calc(var(--s4) + 4px); }
@keyframes drop { from { opacity: 0; transform: translateY(-4px) scaleY(.96); } }
.answer, .did { animation: rise .4s cubic-bezier(.2, .7, .2, 1) both; }
.answer { margin-bottom: var(--s3); }
aside > * { animation: rise .5s cubic-bezier(.2, .7, .2, 1) both; animation-delay: .12s; }
.infobox img { transition: transform .6s cubic-bezier(.2, .7, .2, 1); }
.infobox:hover img { transform: scale(1.03); }
.related a { text-decoration: none; position: relative; transition: padding-left .2s cubic-bezier(.2, .7, .2, 1); }
.related a::before { content: "→"; position: absolute; left: 0; opacity: 0; transform: translateX(-6px);
  transition: opacity .2s ease, transform .2s ease; }
.related a:hover { padding-left: 1.3em; }
.related a:hover::before { opacity: 1; transform: none; }

.pages a { text-decoration: none; padding: 2px 10px; border-radius: 999px; border: 1px dotted var(--line-strong);
  transition: background-color .2s ease, border-color .2s ease; }
.pages a:hover { background: var(--hover); border-style: solid; border-color: var(--accent); }
.home .mark svg { animation: float 5s ease-in-out infinite; }
@keyframes float { 50% { transform: translateY(-4px) rotate(-3deg); } }
/* A thin bar runs along the top while the next page of results is on its way. */
body.busy::before { content: ""; position: fixed; top: 0; left: 0; height: 2px; width: 40%; z-index: 50;
  background: linear-gradient(90deg, transparent, var(--accent), transparent); animation: sweep 1s ease-in-out infinite; }
@keyframes sweep { from { transform: translateX(-100%); } to { transform: translateX(260%); } }
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation: none !important; transition: none !important; }
}
@media (max-width: 980px) { .layout { grid-template-columns: minmax(0, 1fr); } }
@media (max-width: 560px) { .hit.media { grid-template-columns: minmax(0, 1fr); } .hit.media .thumb { width: 100%; } }
"""

SCRIPT = site_ui.SCRIPT + """
document.addEventListener("DOMContentLoaded", () => {
  const box = document.querySelector("form.q input[type=search]");
  const list = document.querySelector("form.q .suggest");
  let timer, chosen = -1;
  const show = (items) => {
    chosen = -1;
    list.innerHTML = "";
    for (const text of items.slice(0, 8)) {
      const li = document.createElement("li");
      li.textContent = text;
      li.onmousedown = (e) => { e.preventDefault(); box.value = text; box.form.submit(); };
      list.append(li);
    }
  };
  const mark = () => [...list.children].forEach((li, i) => li.classList.toggle("on", i === chosen));
  if (box && list) {
    box.addEventListener("input", () => {
      clearTimeout(timer);
      const q = box.value.trim();
      if (q.length < 2 || q.startsWith("!")) return show([]);
      timer = setTimeout(async () => {
        try {
          const r = await fetch("/ac?q=" + encodeURIComponent(q));
          const data = await r.json();
          if (box.value.trim() === q) show(data[1] || []);
        } catch (e) { show([]); }
      }, 140);
    });
    box.addEventListener("keydown", (e) => {
      const n = list.children.length;
      if (!n) return;
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        chosen = (chosen + (e.key === "ArrowDown" ? 1 : n - 1 + (chosen < 0 ? 1 : 0))) % n;
        mark();
        box.value = list.children[chosen].textContent;
      } else if (e.key === "Escape") show([]);
    });
    box.addEventListener("blur", () => setTimeout(() => show([]), 100));
  }
  // The bar along the top while the next results load.
  const busy = () => document.body.classList.add("busy");
  document.querySelectorAll("form.q").forEach((f) => f.addEventListener("submit", busy));
  document.querySelectorAll('.tabs a, .filters a, .pages a, .related a, .did a').forEach((a) => a.addEventListener("click", busy));
  window.addEventListener("pageshow", () => document.body.classList.remove("busy"));
  // A picture that fails takes its tile or its slot with it.
  document.querySelectorAll(".images img, .hit img").forEach((img) => img.addEventListener("error", () => {
    if (img.closest(".images")) img.closest("a").remove(); else img.remove();
  }));
  const hits = [...document.querySelectorAll(".hit")];
  let at = -1;
  document.addEventListener("keydown", (e) => {
    if (e.target.matches("input, textarea, select")) return;
    if (e.key === "/") { e.preventDefault(); box && (box.focus(), box.select()); return; }
    if (!hits.length || !["j", "k", "Enter", "o"].includes(e.key)) return;
    if (e.key === "Enter" || e.key === "o") { const a = hits[at]?.querySelector("h3 a"); if (a) location.href = a.href; return; }
    hits[at]?.classList.remove("focus");
    at = Math.max(0, Math.min(hits.length - 1, at + (e.key === "j" ? 1 : -1)));
    hits[at].classList.add("focus");
    hits[at].scrollIntoView({block: "nearest"});
  });
});
"""


def text(value):
    """Engine text arrives with HTML entities in it; decoded once, then escaped for the page."""
    return html.escape(html.unescape(str(value)))


def secret():
    return SECRET.read_text().strip()


def signed(path, url):
    """An address for searx's own proxy, which fetches `url` from hive instead of the browser."""
    if not url or url.startswith("data:"):
        return url
    if url.startswith("//"):
        url = "https:" + url
    sig = hmac.new(secret().encode(), url.encode(), hashlib.sha256).hexdigest()
    return f"{path}?url={quote(url, safe='')}&h={sig}"


def favicon(url):
    parts = urlparse(url)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        return ""
    return signed("/favicon_proxy", f"{parts.scheme}://{parts.netloc}")


def ask(path, params):
    """searx's answer: (status, JSON or None, a redirect or None)."""
    conn = http.client.HTTPConnection(*ENGINE.rsplit(":", 1), timeout=20)
    try:
        conn.request("GET", f"{path}?{urlencode(params)}", headers={"Accept": "application/json"})
        res = conn.getresponse()
        body = res.read()
        if res.status in (301, 302, 303, 307, 308):
            return res.status, None, res.getheader("Location")
        try:
            return res.status, json.loads(body or b"null"), None
        except ValueError:
            return res.status, None, None
    finally:
        conn.close()


def page(title, body, name, here, *, active="search"):
    out = site_ui.page(site=SITE, title=title, body=body, links=LINKS, active=active, name=name, here=here,
                       style=STYLE, script=SCRIPT)
    # The browser offers to add the site as a search engine from this link.
    return out.replace("</title>", '</title><link rel=search type="application/opensearchdescription+xml" '
                       'title=search href="/opensearch.xml"><link rel=icon href="/favicon.svg">', 1)


def box(q="", category="general", autofocus=False):
    e = html.escape
    keep = f'<input type=hidden name=c value="{e(category)}">' if category != "general" else ""
    return (f'<form class=q action=/search method=get role=search>'
            f'<input type=search name=q value="{e(q)}" placeholder="Search the web" autocomplete=off '
            f'spellcheck=false aria-label=Search{" autofocus" if autofocus else ""}>{keep}'
            f'<ul class=suggest></ul><button type=submit>{site_ui.icon("search")}</button></form>')


def home(name):
    body = (f'<div class=home><div class=mark>{site_ui.logo()}<span>search</span></div>{box(autofocus=True)}'
            f'<div class=hint><kbd>/</kbd> to search · <kbd>j</kbd> <kbd>k</kbd> to move through results · '
            f'<code>!w</code> <code>!gh</code> <code>!yt</code> to pick an engine · <code>!!g</code> to go straight there</div></div>')
    return page("search", body, name, "/")


def link(q, **over):
    params = {"q": q, **{k: v for k, v in over.items() if v not in ("", None, 1, "general")}}
    return "/search?" + urlencode(params)


def hit(r, i=0):
    e = html.escape
    url = r.get("url") or ""
    parts = urlparse(url)
    where = e(parts.netloc + (parts.path if parts.path != "/" else ""))
    icon = favicon(url)
    head = (f'<div class=where>{f"<img src=\"{e(icon)}\" alt=\"\" loading=lazy>" if icon else ""}<span>{where}</span></div>'
            f'<h3><a href="{e(url)}" rel="noreferrer noopener">{text(r.get("title") or url)}</a></h3>')
    content = r.get("content") or ""
    meta = []
    if r.get("publishedDate"):
        stamp = str(r["publishedDate"])
        meta.append(f"<span>{e(stamp[:10] if stamp[:4].isdigit() and stamp[4:5] == '-' else stamp)}</span>")
    if r.get("author"):
        meta.append(f"<span>{text(r['author'])}</span>")
    meta += [f'<span class=eng>{e(x)}</span>' for x in (r.get("engines") or [r.get("engine")]) if x]
    inner = f'{head}{f"<p>{text(content)}</p>" if content else ""}<div class=meta>{"".join(meta)}</div>'
    thumb = r.get("thumbnail") or (r.get("img_src") if "video" in (r.get("template") or "") else "")
    if thumb:
        return (f'<div class="hit media" style="--i:{min(i, 14)}"><img class=thumb src="{e(signed("/image_proxy", thumb))}" alt="" loading=lazy>'
                f'<div>{inner}</div></div>')
    return f'<div class=hit style="--i:{min(i, 14)}">{inner}</div>'


def image(r, i=0):
    e = html.escape
    src = r.get("thumbnail") or r.get("thumbnail_src") or r.get("img_src") or ""
    full = r.get("img_src") or r.get("url") or ""
    return (f'<a href="{e(r.get("url") or full)}" title="{text(r.get("title") or "")}" rel="noreferrer noopener" style="--i:{min(i, 30)}">'
            f'<span class=frame><img src="{e(signed("/image_proxy", src))}" alt="" loading=lazy></span><span>{text(r.get("title") or "")}</span>'
            f'<span>{e(urlparse(r.get("url") or "").netloc)}</span></a>')


def answer(a):
    e = html.escape
    if isinstance(a, dict):
        said = a.get("answer") or a.get("content") or ""
        url = a.get("url")
        return f'<div class=answer>{text(said)}{f" <a href=\"{e(url)}\">source</a>" if url else ""}</div>'
    return f'<div class=answer>{text(a)}</div>'


def infobox(b):
    e = html.escape
    img = f'<img src="{e(signed("/image_proxy", b["img_src"]))}" alt="">' if b.get("img_src") else ""
    # SearXNG sends attributes as [{label, value}]; searx as {label: value}.
    raw = b.get("attributes") or []
    pairs = raw.items() if isinstance(raw, dict) else [(a.get("label", ""), a.get("value", "")) for a in raw if isinstance(a, dict)]
    attrs = "".join(f'<dt>{text(k)}</dt><dd>{text(v)}</dd>' for k, v in list(pairs)[:12] if v)
    urls = "".join(f'<a href="{e(u.get("url", ""))}" rel="noreferrer noopener">{e(u.get("title", ""))}</a>'
                   for u in (b.get("urls") or [])[:6] if u.get("url"))
    about = f'<p>{text(b["content"])}</p>' if b.get("content") else ""
    return (f'<div class=infobox>{img}<div class=body><h3>{text(b.get("infobox") or b.get("title") or "")}</h3>{about}'
            f'{f"<dl>{attrs}</dl>" if attrs else ""}{f"<div class=links>{urls}</div>" if urls else ""}</div></div>')


def results_page(name, query):
    e = html.escape
    q = (query.get("q") or [""])[0].strip()
    category = (query.get("c") or ["general"])[0]
    category = category if category in KNOWN else "general"
    when = (query.get("t") or [""])[0]
    when = when if when in {k for k, _ in TIMES} else ""
    try:
        pageno = max(1, min(int((query.get("p") or ["1"])[0]), 20))
    except ValueError:
        pageno = 1
    if not q:
        return 302, "/"
    params = {"q": q, "format": "json", "categories": category, "pageno": pageno}
    if when:
        params["time_range"] = when
    status, data, redirect = ask("/search", params)
    if redirect:
        return 302, redirect
    here = link(q, c=category, t=when, p=pageno)
    tabs = site_ui.tabs([(link(q, c=key, t=when), label, ico, None, None, key == category) for key, label, ico in CATEGORIES])
    times = "".join(f'<a href="{e(link(q, c=category, t=key))}" class="{"on" if key == when else ""}">{e(label)}</a>'
                    for key, label in TIMES)
    if not isinstance(data, dict):
        body = (f'<div class=qbar>{box(q, category)}{tabs}</div>'
                f'<div class=empty>searx did not answer ({status}). Try again in a moment.</div>')
        return 200, page(q, body, name, here)
    results = data.get("results") or []
    found = data.get("number_of_results") or 0
    summary = f'{len(results)} results' + (f' of about {found:,}' if found and found > len(results) else "")
    main = "".join(answer(a) for a in data.get("answers") or [])
    corrections = [c for c in data.get("corrections") or [] if isinstance(c, str)]
    if corrections:
        main += '<div class=did>Did you mean ' + ", ".join(
            f'<a href="{e(link(c, c=category, t=when))}">{e(c)}</a>' for c in corrections[:3]) + "?</div>"
    if category == "images":
        main += f'<div class=images>{"".join(image(r, i) for i, r in enumerate(results))}</div>'
    else:
        main += "".join(hit(r, i) for i, r in enumerate(results))
    if not results and not data.get("answers"):
        main += f'<div class=empty>Nothing found for <b>{e(q)}</b>.</div>'
    nav = ""
    if pageno > 1:
        nav += f'<a href="{e(link(q, c=category, t=when, p=pageno - 1))}">← Previous</a>'
    if results:
        nav += f'<span class=mute>page {pageno}</span><a href="{e(link(q, c=category, t=when, p=pageno + 1))}">Next →</a>'
    slow = data.get("unresponsive_engines") or []
    slow_note = ("<div class=slow>No answer from " + ", ".join(e(str(s[0] if isinstance(s, list) else s)) for s in slow)
                 + "</div>") if slow else ""
    side = "".join(infobox(b) for b in (data.get("infoboxes") or [])[:2])
    related = [s for s in data.get("suggestions") or [] if isinstance(s, str)]
    if related:
        side += site_ui.section("Related", '<div class=related>' + "".join(
            f'<a href="{e(link(s, c=category))}">{e(s)}</a>' for s in related[:8]) + "</div>")
    body = (f'<div class=qbar>{box(q, category)}{tabs}<div class=filters>{times}<span>· {e(summary)}</span></div></div>'
            f'<div class="layout{" wide" if category == "images" else ""}"><div><div class=results>{main}</div><div class=pages>{nav}</div>{slow_note}</div>'
            f'<aside>{side}</aside></div>')
    return 200, page(q, body, name, here)


def engines_page(name):
    e = html.escape
    status, data, _ = ask("/config", {})
    engines = (data or {}).get("engines") or []
    rows = sorted(((x.get("name", ""), ", ".join(x.get("categories") or []), "on" if x.get("enabled") else "off")
                   for x in engines if isinstance(x, dict)), key=lambda r: (r[2] != "on", r[0]))
    on = sum(1 for r in rows if r[2] == "on")
    body = (site_ui.band("Engines", "search", summary=f"{on} of {len(rows)} enabled · "
                         f'<a href="{SOURCE}">searx source</a> (AGPL-3.0)')
            + site_ui.section("Engines", site_ui.table(["Engine", "Categories", "State"],
                                                       [[e(a), e(b), site_ui.pill("ok" if c == "on" else "none", c)] for a, b, c in rows])))
    return page("engines", body, name, "/engines", active="engines")


def opensearch():
    base = f"https://{DOMAIN}"
    return f"""<?xml version="1.0" encoding="utf-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/" xmlns:moz="http://www.mozilla.org/2006/browser/search/">
  <ShortName>search</ShortName>
  <Description>search.bresilla.com</Description>
  <InputEncoding>UTF-8</InputEncoding>
  <Image type="image/svg+xml">{base}/favicon.svg</Image>
  <Url type="text/html" method="get" template="{base}/search?q={{searchTerms}}"/>
  <Url type="application/x-suggestions+json" method="get" template="{base}/ac?q={{searchTerms}}"/>
  <moz:SearchForm>{base}/</moz:SearchForm>
</OpenSearchDescription>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "search"

    def reply(self, code, body, kind="text/html; charset=utf-8", headers=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        try:
            self.route()
        except Exception as error:
            traceback.print_exception(error)
            self.reply(500, page("error", '<div class=empty>Something went wrong drawing this page.</div>', None, "/"))

    def route(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        name = self.headers.get("X-Forwarded-Preferred-Username")
        if url.path == "/":
            if query.get("q"):
                return self.reply(302, "", headers=[("Location", "/search?" + url.query)])
            return self.reply(200, home(name))
        if url.path == "/search":
            code, out = results_page(name, query)
            if code == 302:
                return self.reply(302, "", headers=[("Location", out)])
            return self.reply(code, out)
        if url.path == "/ac":
            q = (query.get("q") or [""])[0]
            _, data, _ = ask("/autocompleter", {"q": q}) if len(q) >= 2 else (200, None, None)
            # searx answers either a flat list or OpenSearch's [query, [suggestions]].
            items = data if isinstance(data, list) else []
            if len(items) == 2 and isinstance(items[1], list):
                items = items[1]
            return self.reply(200, json.dumps([q, [s for s in items if isinstance(s, str) and s.strip().lower() != q.strip().lower()]]),
                              "application/x-suggestions+json")
        if url.path == "/engines":
            return self.reply(200, engines_page(name))
        if url.path == "/opensearch.xml":
            return self.reply(200, opensearch(), "application/opensearchdescription+xml")
        if url.path == "/favicon.svg":
            return self.reply(200, site_ui.logo(), "image/svg+xml")
        if url.path == "/healthz":
            return self.reply(200, "ok", "text/plain")
        self.reply(404, page("not found", '<div class=empty>Nothing here.</div>', name, url.path))

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    host, port = LISTEN.rsplit(":", 1)
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()
