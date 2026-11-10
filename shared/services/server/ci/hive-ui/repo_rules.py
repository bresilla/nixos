"""Repository trigger and publishing forms."""
import json


MODES = (("push", "Branch updates"), ("tag", "Matching tags on selected branches"),
         ("push_or_tag", "Branch updates or matching tags"), ("manual", "Manual only"))
PATTERNS = (("branches", "Branches (empty means the registered branch)"),
            ("branches_ignore", "Excluded branches"), ("tags", "Tags"),
            ("tags_ignore", "Excluded tags"), ("paths", "Changed paths to include"),
            ("paths_ignore", "Changed paths to ignore"))


def page(ui, user, forge, owner, name, flash):
    base = f"/-/repo/{forge}/{ui.quote(owner)}/{ui.quote(name)}"
    data = ui.service_api("GET", ui.repo_path(forge, owner, name) + "/settings", user)
    config = data["config"]
    trigger = config.get("trigger") or {"branches": [data["default_branch"], *config.get("branches", [])]}
    cache = config.get("cache") or {}
    e = ui.e
    options = "".join(f'<option value="{value}"{" selected" if trigger.get("mode", "push") == value else ""}>{label}</option>'
                      for value, label in MODES)
    fields = f'<label>Trigger<select name=mode>{options}</select></label>'
    for key, title in PATTERNS:
        value = "\n".join(trigger.get(key, ["v*"] if key == "tags" else []))
        fields += f'<label>{title}<textarea name="{key}" rows=2>{e(value)}</textarea></label>'
    fields += ('<label><input type=checkbox name=manual value=yes'
               + (' checked' if trigger.get("manual", True) else '') + '> Allow Build now</label>')
    for key, title, default in (("flake_dir", "Flake directory", "."), ("attribute", "Output attribute", "checks"),
                                ("lock_file", "Lock file", "flake.lock")):
        fields += f'<label>{title}<input class=wide name="{key}" value="{e(config.get(key, default))}" required></label>'
    fields += f'<label>Cache (empty means server default)<input class=wide name=cache value="{e(cache.get("default") or "")}"></label>'
    fields += ('<label><input type=checkbox name=pin value=yes' + (' checked' if cache.get("pin") else '')
               + '> Maintain pins on the registered default branch</label>')
    pin_name = cache.get("pin_name", "{name}-{system}")
    if not cache.get("pin") and pin_name == "{name}":
        pin_name = "{name}-{system}"
    fields += f'<label>Pin name<input class=wide name=pin_name value="{e(pin_name)}" required></label>'
    fields += f'<label>Outputs not to pin<textarea name=no_pin rows=2>{e(chr(10).join(cache.get("no_pin", [])))}</textarea></label>'
    routing = cache.get("rules", [])
    if isinstance(routing, dict):
        routing = list(routing.items())
    fields += f'<label>Cache routing (pattern=cache, first match wins)<textarea name=cache_rules rows=2>{e(chr(10).join(a + "=" + b for a, b in routing))}</textarea></label>'
    source = e(data.get("source", "defaults")) if data.get("effective") else "pending refresh"
    note = ('<p class=mute>Patterns use globs, one per line. Includes and excludes apply together. '
            'Tags build the tagged commit only after it is on a selected branch. The first scan selects '
            'the newest eligible tag; later scans process new matching tags. Path filters cover changes '
            'since the previous observed head or release. Build now bypasses path filters, not tag/branch rules.</p>')
    precedence = ('<p><code>.muros.lua</code> overrides these fallback settings when present. Scheduling rules '
                  'come from the registered default branch; build recipes come from the selected commit.</p>')
    error = f'<p class=bad>{e(data["error"])}</p>' if data.get("error") else ''
    effective = e(json.dumps(data.get("effective"), indent=2))
    body = (f'<div class=crumbs><a href="{base}">{e(owner)}/{e(name)} ›</a></div>'
            f'<div class=pagehead><h1>Repository rules</h1></div><section class=set><h3>effective configuration: {source}</h3>'
            f'<div>{precedence}{error}<p class=mute>{e(data.get("decision", ""))}</p>'
            f'<details><summary>Effective settings</summary><pre>{effective}</pre></details></div></section>'
            f'<section class=set><h3>UI fallback settings</h3><div>{note}<form class=repo-rules method=post action="{base}/settings">'
            f'{fields}<button>Save rules</button></form></div></section>')
    return ui.layout(f"{owner}/{name} rules", body, user, flash, "repos")


def parse(form):
    def lines(key):
        return [line.strip() for line in form.get(key, "").splitlines() if line.strip()]
    trigger = {key: lines(key) for key, _ in PATTERNS}
    trigger.update(mode=form.get("mode", "push"), manual=form.get("manual") == "yes")
    routing = []
    for line in lines("cache_rules"):
        pattern, separator, cache = line.partition("=")
        if not separator or not pattern.strip() or not cache.strip():
            raise ValueError("cache routing needs pattern=cache on each line")
        routing.append([pattern.strip(), cache.strip()])
    return {"trigger": trigger, "flake_dir": form.get("flake_dir", "."),
            "attribute": form.get("attribute", "checks"), "lock_file": form.get("lock_file", "flake.lock"),
            "cache": {"default": form.get("cache", "").strip() or None, "pin": form.get("pin") == "yes",
                      "pin_name": form.get("pin_name", "{name}-{system}"), "no_pin": lines("no_pin"), "rules": routing}}
