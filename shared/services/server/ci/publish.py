"""Publishes one CI result: pushes it to the cache its repository names, and pins it.

nixbot runs this after every successful build, with the build in CI_* variables.
The repository says where its results go, in its nixbot.toml (nixbot ignores
the [cache] table):

    [cache]
    default = "firmwares"        # where results go; "bresilla" when unset
    pin = true                   # pin each result, on the default branch only
    pin_name = "{name}"          # or "{name}-{system}"
    [cache.rules]
    "kernel-*" = "kernels"       # attribute name pattern -> cache

A build that fails never gets here, so its pin keeps the last good result.
"""
import fnmatch
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import urllib.request

ATTIC = os.environ["CI_ATTIC"]
GIT = os.environ["CI_GIT"]
CACHE = os.environ["CI_CACHE"]
REPOS = os.environ["CI_REPOS"]
CREDENTIALS = os.environ.get("CREDENTIALS_DIRECTORY", "")


def secret(name):
    try:
        with open(os.path.join(CREDENTIALS, name)) as f:
            return f.read().strip()
    except OSError:
        return ""


def repo_url(project):
    with open(REPOS) as f:
        repos = json.load(f)
    for key, repo in repos.items():
        if key == project or key.rpartition("/")[2] == project:
            return repo["url"]
    return None


def cache_config(url, branch, revision):
    """The [cache] table of nixbot.toml on the branch, read once per commit."""
    seen = os.path.join(tempfile.gettempdir(), f"ci-publish-{revision}.json")
    if os.path.exists(seen):
        with open(seen) as f:
            return json.load(f)
    with tempfile.TemporaryDirectory() as work:
        subprocess.run([GIT, "init", "-q", work], check=True)
        subprocess.run([GIT, "-C", work, "fetch", "-q", "--depth", "1", url, branch], check=True)
        shown = subprocess.run([GIT, "-C", work, "show", "FETCH_HEAD:nixbot.toml"], capture_output=True, text=True)
    config = tomllib.loads(shown.stdout).get("cache", {}) if shown.returncode == 0 else {}
    with open(seen, "w") as f:
        json.dump(config, f)
    return config


def main():
    attr, system, out = os.environ["CI_ATTR"], os.environ["CI_SYSTEM"], os.environ["CI_OUT"]
    project, branch = os.environ["CI_PROJECT"], os.environ["CI_BRANCH"]
    if not out:
        print(f"{attr}: no out path, nothing to publish")
        return
    name = attr.rpartition(".")[2].strip('"')
    url = repo_url(project)
    config = cache_config(url, branch, os.environ["CI_REVISION"]) if url else {}
    target = next((cache for pattern, cache in config.get("rules", {}).items() if fnmatch.fnmatch(name, pattern)),
                  config.get("default", "bresilla"))

    token = secret("attic-token")
    if not token:
        sys.exit("no attic token: set it on build.bresilla.com/-/settings")
    env = {**os.environ, "HOME": tempfile.gettempdir()}
    subprocess.run([ATTIC, "login", "ci", CACHE, token], check=True, env=env, stdout=subprocess.DEVNULL)
    subprocess.run([ATTIC, "push", f"ci:{target}", out], check=True, env=env)
    print(f"{attr}: pushed to {target}")

    if not config.get("pin") or branch != os.environ["CI_DEFAULT_BRANCH"]:
        return
    pin_token = secret("pin-token")
    if not pin_token:
        sys.exit("no pin token: set it on build.bresilla.com/-/settings")
    pin = config.get("pin_name", "{name}").format(name=name, system=system)
    request = urllib.request.Request(f"{CACHE}/-/pins/{pin}", data=out.encode(), method="PUT",
                                     headers={"Authorization": f"Bearer {pin_token}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        print(f"{attr}: pinned {pin} ({response.status})")


if __name__ == "__main__":
    main()
