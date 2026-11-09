"""Publishes one CI result: pushes it to the cache its repository names, and pins it.

nixbot runs this after every successful build, with the build in CI_* variables.
The repository says where its results go, in its .nixbot.toml or nixbot.toml
(nixbot ignores the [cache] table):

    [cache]
    default = "firmwares"        # where results go; "packages" when unset
    pin = true                   # pin each result, on the default branch only
    pin_name = "{name}"          # or "{name}-{system}"
    no_pin = ["*-config"]        # cached, but never pinned
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
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ATTIC = os.environ["CI_ATTIC"]
NIX = os.environ["CI_NIX"]
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
        for filename in (".nixbot.toml", "nixbot.toml"):
            shown = subprocess.run([GIT, "-C", work, "show", f"FETCH_HEAD:{filename}"], capture_output=True, text=True)
            if shown.returncode == 0:
                break
    config = tomllib.loads(shown.stdout).get("cache", {}) if shown.returncode == 0 else {}
    with open(seen, "w") as f:
        json.dump(config, f)
    return config


def on_nixos_org(path):
    """Whether cache.nixos.org has it; a failed check fails the step, the old pin stays."""
    name = os.path.basename(path).split("-")[0]
    try:
        urllib.request.urlopen(urllib.request.Request(f"https://cache.nixos.org/{name}.narinfo", method="HEAD"), timeout=20)
        return True
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return False
        raise


def own_paths(out):
    """The paths in its closure that cache.nixos.org lacks: never nixpkgs' own builds."""
    closure = subprocess.run([NIX, "path-info", "--recursive", out], check=True, capture_output=True, text=True).stdout.split()
    with ThreadPoolExecutor(16) as pool:
        return [path for path, there in zip(closure, pool.map(on_nixos_org, closure)) if not there]


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
                  config.get("default", "packages"))

    token = secret("attic-token")
    if not token:
        sys.exit("no attic token: set it on build.bresilla.com/-/settings")
    own = own_paths(out)
    if own:
        env = {**os.environ, "HOME": tempfile.gettempdir()}
        subprocess.run([ATTIC, "login", "ci", CACHE, token], check=True, env=env, stdout=subprocess.DEVNULL)
        subprocess.run([ATTIC, "push", "--no-closure", f"ci:{target}", *own], check=True, env=env)
    print(f"{attr}: pushed {len(own)} path(s) to {target}")

    if not config.get("pin") or branch != os.environ["CI_DEFAULT_BRANCH"] \
            or any(fnmatch.fnmatch(name, p) for p in config.get("no_pin", [])):
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
