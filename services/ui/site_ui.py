"""Shared HTML presentation for the build and cache frontends."""
import html
import json
import re
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent
STYLE = (ROOT / "tokens.css").read_text() + (ROOT / "header.css").read_text() + (ROOT / "base.css").read_text()
SCRIPT = (ROOT / "theme.js").read_text() + """
BresillaUI.accent();
document.addEventListener("DOMContentLoaded", () => {
  const mark = document.querySelector("header svg");
  if (mark) BresillaUI.icon(mark.outerHTML, {append: true});
  BresillaUI.selects();
});
"""
SIGN_OUT = "/oauth2/sign_out?rd=https%3A%2F%2Fid.bresilla.com%2Fui%2Flogout"
_HEADER = (ROOT / "header.html").read_text().rstrip("\n")
_LOGO = (ROOT / "logo.svg").read_text().split("?>", 1)[-1]
_LOGO = re.sub(r'fill="#[0-9a-fA-F]+"', 'fill="currentColor"', _LOGO)
_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{}</svg>'
ICONS = {name: _ICON.format(shape) for name, shape in json.loads((ROOT / "icons.json").read_text()).items()}


def logo():
    return _LOGO


PAGE_NAMES = {"caches", "repositories", "builders", "settings", "new cache", "pins", "sign in",
              "peers", "groups", "access", "new peer"}


def tab_title(site, title):
    """Every tab reads "page · site"; the sites' own page names start with a capital."""
    page = title[:1].upper() + title[1:] if title in PAGE_NAMES else title
    return f"{page} · {site}" if page and page != site else site


def page(*, site, title, body, links, active, name=None, here="/", flash="", style=STYLE, script=SCRIPT, account_extra="",
         sign_in=True):
    e = html.escape
    nav = "".join(f'<a href="{e(href)}" class="{"on" if key == active else ""}">{e(label)}</a>' for key, href, label in links)
    # account_extra: a site's own control beside the account name (already HTML).
    # sign_in=False: a site with no login shows no account link at all.
    account = account_extra + (f'<span class=mute>{e(name)}</span><a href="{SIGN_OUT}" class=item>Sign out</a>' if name
                               else f'<a href="/oauth2/start?rd={quote(here)}" class=item>Sign in</a>' if sign_in else "")
    values = {"ATTRS": "", "LOGO": logo(), "HOME": "/", "NAME": e(site), "NAV": nav, "ACCOUNT": account}
    header = re.sub(r"@(ATTRS|LOGO|HOME|NAME|NAV|ACCOUNT)@", lambda match: values[match[1]], _HEADER)
    note = f'<div class=flash>{e(flash)}</div>' if flash else ""
    return f"""<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1"><title>{e(tab_title(site, title))}</title>
<script>{script}</script><style>{style}</style></head><body>
{header}
<main>{note}{body}</main></body></html>"""


# --- Shared page parts: the band with its tabs, tiles, states, panels. -------------------
# status, cache and build draw their pages from these, so they read alike (base.css).

RANK = {"ok": 0, "none": 0, "warn": 1, "fail": 2}


def icon(name):
    return ICONS.get(name, "")


def dot(state):
    return f'<span class="st {state}"></span>'


def pill(state, text=None):
    return f'<span class="pill {state}">{html.escape(text or state)}</span>'


def worst(states):
    return max(states, key=lambda s: RANK.get(s, 0), default="ok")


def bar(share):
    """A share from 0 to 1 as a bar and a percentage, and the state it puts the thing in."""
    state = "fail" if share > 0.9 else "warn" if share > 0.8 else "ok"
    return f'<span class=bar><i class={state} style="width:{min(share, 1) * 100:.0f}%"></i></span>{share:.0%}', state


def spark(values, width=110, height=22):
    values = [v for v in values if v is not None]
    if len(values) < 2:
        return '<span class=mute>—</span>'
    low, high = min(values), max(values)
    span, step = (high - low) or 1, width / (len(values) - 1)
    points = " ".join(f"{i * step:.1f},{height - 2 - (v - low) / span * (height - 4):.1f}" for i, v in enumerate(values))
    return f'<svg class=spark width={width} height={height} viewBox="0 0 {width} {height}"><polyline points="{points}"/></svg>'


def tabs(items):
    """items: (href, label, icon name, count, count state, chosen)."""
    e = html.escape
    out = ""
    for href, label, ico, count, state, on in items:
        badge = f'<span class="count {state or ""}">{e(str(count))}</span>' if count else ""
        out += f'<a href="{e(href)}" class="{"on" if on else ""}">{icon(ico)}<span class=label>{e(label)}</span>{badge}</a>'
    return f"<div class=tabs>{out}</div>" if out else ""


def band(title, ico="", *, crumbs=(), summary="", items=(), small=""):
    """The strip under the header: breadcrumbs, the title, what it adds up to, and tabs."""
    e = html.escape
    trail = "".join(f'<a href="{e(href)}">{e(label)}</a> /' for href, label in crumbs)
    head = (f'<div class=head><div class=title>{icon(ico)}{e(title)}{f" <small>{e(small)}</small>" if small else ""}</div>'
            f'<div class=summary>{summary}</div></div>')
    return f'<div class=band>{f"<div class=crumbs>{trail}</div>" if trail else ""}{head}{tabs(items)}</div>'


def tile(title, rows, state=None, *, href=None, note="", foot=""):
    """A small card: a title (with a state pill), labelled facts, an optional footer."""
    e = html.escape
    facts = "".join(f"<dt>{e(k)}</dt><dd>{v}</dd>" for k, v in rows)
    head = f'<h3>{dot(state) if state else ""}{e(title)}{note}</h3>'
    body = f'{head}{f"<dl>{facts}</dl>" if facts else ""}{f"<div class=foot>{foot}</div>" if foot else ""}'
    return f'<a class=tile href="{e(href)}">{body}</a>' if href else f"<div class=tile>{body}</div>"


def section(title, body, state=None, note="", kind=""):
    e = html.escape
    extra = f' <span class=mute style="font-weight:normal">· {e(note)}</span>' if note else ""
    return f'<section class="set {kind}"><h3>{dot(state) if state else ""}{e(title)}{extra}</h3><div>{body}</div></section>'


def reveal(label, body, *, ico="plus", kind="", open_=False):
    """A button that opens a panel under it: forms and long explanations stay folded away."""
    return (f'<details class="reveal {kind}"{" open" if open_ else ""}><summary>{icon(ico)}{html.escape(label)}</summary>'
            f'<div class=panel>{body}</div></details>')


def table(head, rows, numeric=()):
    e = html.escape
    if not rows:
        return '<div class="empty">nothing here</div>'
    th = "".join(f'<th class="{"num" if i in numeric else ""}">{e(h)}</th>' for i, h in enumerate(head))
    body = "".join("<tr>" + "".join(f'<td class="{"num" if i in numeric else ""}">{c}</td>' for i, c in enumerate(row)) + "</tr>"
                   for row in rows)
    return f"<table><tr>{th}</tr>{body}</table>"
