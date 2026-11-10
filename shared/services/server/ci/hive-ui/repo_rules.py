"""Repository trigger and publishing forms."""
import json


MODES = (("push", "Branch updates"), ("tag", "Tags only"),
         ("push_or_tag", "Branch updates and tags"), ("manual", "Manual only"))
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
    def patterns(key, title, hint=""):
        values = trigger.get(key, ["v*"] if key == "tags" else [])
        return (f'<label>{title}<textarea name="{key}" rows="{min(3, max(1, len(values)))}" '
                f'spellcheck=false>{e(chr(10).join(values))}</textarea>'
                + (f'<small class=mute>{e(hint)}</small>' if hint else '') + '</label>')

    def field(key, title, value, hint=""):
        return (f'<label>{title}<input class=wide name="{key}" value="{e(value)}">'
                + (f'<small class=mute>{e(hint)}</small>' if hint else '') + '</label>')

    manual = ('<label class=rules-check><input type=checkbox name=manual value=yes'
              + (' checked' if trigger.get("manual", True) else '') + '> Allow Build now</label>')
    trigger_fields = (f'<div class=rules-grid><label>Build when<select name=mode>{options}</select></label>{manual}'
                      + patterns("branches", "Branches", "Empty uses " + data["default_branch"] + ". One pattern per line.")
                      + patterns("tags", "Tag patterns", "For tag builds. The tagged commit must belong to a selected branch.") + '</div>')
    filters = (patterns("branches_ignore", "Ignore branches") + patterns("tags_ignore", "Ignore tags")
               + patterns("paths", "Only when these files change", "Empty matches any file.")
               + patterns("paths_ignore", "Ignore changed files", "Examples: docs/** or *.md"))
    count = sum(len(trigger.get(key, [])) for key in ("branches_ignore", "tags_ignore", "paths", "paths_ignore"))
    trigger_fields += (f'<details class=rules-extra><summary>Filters <span class=mute>{count} configured</span></summary>'
                       f'<div class=rules-grid>{filters}</div></details>')
    pin_name = cache.get("pin_name", "{name}-{system}")
    if not cache.get("pin") and pin_name == "{name}":
        pin_name = "{name}-{system}"
    publish = ('<div class=rules-grid>' + field("cache", "Cache", cache.get("default") or "", "Empty uses the server default.")
               + field("pin_name", "Pin name", pin_name, "{name}-{system} keeps architectures separate.") + '</div>'
               + '<label class=rules-check><input type=checkbox name=pin value=yes'
               + (' checked' if cache.get("pin") else '') + '> Update pins after successful builds on '
               + e(data["default_branch"]) + '</label>')
    routing = cache.get("rules", [])
    if isinstance(routing, dict):
        routing = list(routing.items())
    publish += ('<details class=rules-extra><summary>Cache routing and pin exclusions</summary><div class=rules-grid>'
                f'<label>Do not pin these outputs<textarea name=no_pin rows=2>{e(chr(10).join(cache.get("no_pin", [])))}</textarea></label>'
                f'<label>Route outputs to caches<textarea name=cache_rules rows=2>{e(chr(10).join(a + "=" + b for a, b in routing))}</textarea>'
                '<small class=mute>One pattern=cache per line; first match wins.</small></label></div></details>')
    build = ''.join(field(key, title, config.get(key, default)) for key, title, default in (
        ("flake_dir", "Flake directory", "."), ("attribute", "Output attribute", "checks"), ("lock_file", "Lock file", "flake.lock")))
    source = data.get("source", "defaults") if data.get("effective") else "pending refresh"
    note = ('<code>.muros.lua</code> overrides these fallback settings. Edit the file to change the active rules.'
            if source == ".muros.lua" else 'No file required. A <code>.muros.lua</code> file takes precedence when present.')
    error = f'<p class=bad>{e(data["error"])}</p>' if data.get("error") else ''
    effective = e(json.dumps(data.get("effective"), indent=2))
    body = (f'<div class=crumbs><a href="{base}">{e(owner)}/{e(name)} ›</a></div>'
            f'<div class=pagehead><h1>Repository rules</h1><a href="{base}">Back to builds</a></div>'
            f'<form class=repo-rules method=post action="{base}/settings">'
            f'<p class=rules-source><span class=pill>{e(source)}</span> {note}</p>{error}'
            f'<section class=set><h3>Triggers</h3><div>{trigger_fields}</div></section>'
            f'<section class=set><h3>Publish</h3><div>{publish}</div></section>'
            '<details class=rules-extra><summary>Build settings <span class=mute>flake, output, lock file</span></summary>'
            f'<div class=rules-grid>{build}</div></details>'
            f'<div class=rules-actions><button>Save rules</button><span class=mute>Applies on the next poll or Build now.</span></div>'
            '<details class=rules-extra><summary>Effective configuration</summary>'
            f'<p>Source: {e(source)}</p><p>{e(data.get("decision", ""))}</p><pre>{effective}</pre></details></form>')
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
