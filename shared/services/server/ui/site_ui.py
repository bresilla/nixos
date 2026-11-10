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


def page(*, site, title, body, links, active, name=None, here="/", flash="", style=STYLE, script=SCRIPT):
    e = html.escape
    nav = "".join(f'<a href="{e(href)}" class="{"on" if key == active else ""}">{e(label)}</a>' for key, href, label in links)
    account = (f'<span class=mute>{e(name)}</span><a href="{SIGN_OUT}" class=item>Sign out</a>' if name
               else f'<a href="/oauth2/start?rd={quote(here)}" class=item>Sign in</a>')
    values = {"ATTRS": "", "LOGO": logo(), "HOME": "/", "NAME": e(site), "NAV": nav, "ACCOUNT": account}
    header = re.sub(r"@(ATTRS|LOGO|HOME|NAME|NAV|ACCOUNT)@", lambda match: values[match[1]], _HEADER)
    note = f'<div class=flash>{e(flash)}</div>' if flash else ""
    return f"""<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1"><title>{e(title)}</title>
<script>{script}</script><style>{style}</style></head><body>
{header}
<main>{note}{body}</main></body></html>"""
