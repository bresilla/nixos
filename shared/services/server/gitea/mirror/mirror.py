"""Mirrors gitea repositories to and from other git hosts over SSH.

`mirror.py sync` runs every link once, `mirror.py probe` answers the settings
page's checks of a URL. Gitea stays the source of truth: it is read from disk and
written only through its own HTTP git endpoint as the bot, so its hooks run as for
any push. Only branches and tags move, never anything forced over a change the
other side made: a branch both sides changed stops and shows as diverged.
"""
import base64
import fcntl
import glob
import hashlib
import os
import shutil
import socket
import subprocess
import sys
import time

from common import (CONFIG, STATE, blocked, host_key_name, link_id, links_of, mode_blocked,
                    namespace_ok, parse_ssh, pinned_hosts, read_json, repo_rows,
                    target_for, where, write_json)

REPOSITORIES = os.environ["REPOSITORIES"]
GITEA = os.environ.get("GITEA", "http://127.0.0.1:3000")
BOT = os.environ.get("BOT", "git-mirror")
PINNED = os.environ["KNOWN_HOSTS"]
SEED = os.environ.get("NAMESPACES")
RECHECK = int(os.environ.get("RECHECK", "600"))
RUNTIME = os.environ.get("RUNTIME_DIRECTORY", "/run/git-mirror")
REFSPECS = lambda ns: [f"+refs/heads/*:refs/m/{ns}/heads/*", f"+refs/tags/*:refs/m/{ns}/tags/*"]


def now():
    return int(time.time())


def setup():
    """A git and ssh that trust only the pinned host keys and use only the agent."""
    os.makedirs(RUNTIME, exist_ok=True)
    with open(f"{RUNTIME}/gitconfig", "w") as f:
        f.write("[safe]\n\tdirectory = *\n[protocol]\n\tallow = never\n"
                "[protocol \"ssh\"]\n\tallow = always\n[protocol \"file\"]\n\tallow = always\n"
                "[protocol \"http\"]\n\tallow = always\n[gc]\n\tauto = 200\n[core]\n\taskPass =\n")
    # Pinned hosts keep only their pinned keys; the page may add keys for others.
    pinned = pinned_hosts(PINNED)
    with open(f"{RUNTIME}/known_hosts", "w") as out:
        out.write(open(PINNED).read().rstrip("\n") + "\n")
        try:
            for line in open(f"{CONFIG}/known_hosts"):
                parts = line.split()
                if len(parts) >= 3 and not set(parts[0].split(",")) & pinned:
                    out.write(line if line.endswith("\n") else line + "\n")
        except FileNotFoundError:
            pass
    ssh = " ".join([
        "ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", f"UserKnownHostsFile={RUNTIME}/known_hosts", "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "UpdateHostKeys=no", "-o", "IdentityFile=none", "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-o", "ControlMaster=no",
    ])
    os.environ.update({
        "HOME": RUNTIME, "GIT_CONFIG_GLOBAL": f"{RUNTIME}/gitconfig", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_SSH_COMMAND": ssh, "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C",
    })


def git(*args, cwd=None, timeout=300, env=None):
    """(exit code, stdout, stderr); a timeout counts as unreachable."""
    try:
        p = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, **(env or {})})
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timed out: connection timed out"


def agent_up():
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(5)
            s.connect(os.environ.get("SSH_AUTH_SOCK", ""))
        return True
    except OSError:
        return False


def classify(err):
    """(kind, sentence) for a failed ssh or git call."""
    e = err.lower()
    # Without its agent ssh offers no key, which reads like a refused one.
    if ("permission denied" in e or "publickey" in e) and not agent_up():
        return "agent", "the mirror's key agent is not reachable"
    for kind, needles, text in (
        ("hostkey", ("host key is known", "host key verification failed"), "the host's key is not trusted yet"),
        ("hostkey-changed", ("identification has changed",), "the host's key changed; it is not trusted"),
        ("agent", ("authentication agent", "error connecting to agent", "agent refused"), "the mirror's key agent is not reachable"),
        ("unreachable", ("could not resolve", "timed out", "connection refused", "network is unreachable",
                         "no route to host", "connection closed", "connection reset"), "the host is not reachable"),
        ("readonly", ("read only", "read-only", "readonly", "write access", "not allowed to push",
                      "push access", "denied to"), "the key can't write there"),
        ("denied", ("permission denied", "access denied", "publickey"), "the key is not accepted there"),
        ("missing", ("not found", "does not exist", "does not appear to be a git repository",
                     "no such repository"), "the repository does not exist there"),
    ):
        if any(n in e for n in needles):
            return kind, text
    lines = [line for line in err.strip().splitlines() if line.strip()]
    return "error", lines[-1][:200] if lines else "failed"


def keyscan(url):
    """The host's keys as known_hosts lines, for the page to offer trusting them."""
    _, host, port, _ = parse_ssh(url)
    try:
        p = subprocess.run(["ssh-keyscan", "-T", "10", "-p", str(port), host],
                           capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return []
    lines = [line for line in p.stdout.splitlines() if line and not line.startswith("#")]
    out = []
    for line in lines:
        f = subprocess.run(["ssh-keygen", "-lf", "-"], input=line, capture_output=True, text=True)
        out.append({"line": line, "fingerprint": f.stdout.strip()})
    return out


# Probes ------------------------------------------------------------------------

def probe_url(url):
    result = {"url": url, "at": now(), "read": False, "write": False, "modes": [], "hostkeys": []}
    if not parse_ssh(url):
        return {**result, "kind": "invalid", "reason": "not an SSH URL such as git@host:owner/repo.git"}
    code, out, err = git("ls-remote", "--heads", "--tags", url, timeout=40)
    if code != 0:
        kind, text = classify(err)
        result.update(kind=kind, reason=f"not reachable: {text}" if kind != "missing" else f"missing: {text}")
        if kind == "hostkey":
            result["hostkeys"] = keyscan(url)
            result["host"] = host_key_name(*parse_ssh(url)[1:3])
        return result
    result["read"] = True
    result["empty"] = not out.strip()
    # Opens receive-pack and hangs up after its ref list: nothing is sent or changed.
    code, _, err = git("-c", "protocol.version=0", "ls-remote", "--upload-pack=git-receive-pack", url, timeout=40)
    if code == 0:
        result.update(write=True, modes=["push", "pull", "two-way"], kind="ok", reason="the key can read and write there")
        return result
    kind, text = classify(err)
    if kind in ("readonly", "denied", "missing"):
        kind, text = "readonly", "the key can't write there"
    result.update(modes=["pull"], kind=kind, reason=f"only pull: {text}")
    return result


def probe():
    setup()
    os.makedirs(f"{STATE}/probes", exist_ok=True)
    for path in sorted(glob.glob(f"{CONFIG}/spool/probe/*.json")):
        request = read_json(path, None)
        try:
            os.remove(path)
        except FileNotFoundError:
            continue
        name = os.path.basename(path)
        if not request or not all(c in "0123456789abcdef" for c in name[:-5]):
            continue
        write_json(f"{STATE}/probes/{name}", {**probe_url(request.get("url")), "repo": request.get("repo")}, 0o644)
    for path in glob.glob(f"{STATE}/probes/*.json"):
        if os.path.getmtime(path) < time.time() - 86400:
            os.remove(path)


# Syncing -----------------------------------------------------------------------

def refs(work, ns):
    code, out, _ = git("for-each-ref", "--format=%(objectname) %(refname)", f"refs/m/{ns}/", cwd=work)
    prefix = f"refs/m/{ns}/"
    return {name.replace(prefix, "refs/", 1): sha for sha, name in (line.split(" ", 1) for line in out.splitlines())}


def ancestor(work, a, b):
    return git("merge-base", "--is-ancestor", a, b, cwd=work)[0] == 0


def missing_count(work, have, lacks):
    code, out, _ = git("rev-list", "--count", have, f"^{lacks}", cwd=work)
    return int(out.strip() or 0) if code == 0 else 0


def short(name):
    return name.removeprefix("refs/heads/").removeprefix("refs/tags/") + (" (tag)" if name.startswith("refs/tags/") else "")


def plan(work, mode, L, R, B, default_branch):
    """Per ref what moves where: (to remote, to gitea, diverged, ahead, extra)."""
    to_remote, to_gitea, diverged, ahead, extra = [], [], [], [], []
    keep = f"refs/heads/{default_branch}"
    for ref in sorted(set(L) | set(R) | set(B)):
        l, r, b = L.get(ref), R.get(ref), B.get(ref)
        if l == r:
            continue
        branch = ref.startswith("refs/heads/")
        ff = lambda old, new: branch and old and new and ancestor(work, old, new)
        if mode == "push":
            if r == b or r is None or ff(r, l):
                if l is not None or r is not None:
                    to_remote.append((ref, l, r))
            elif l is None:
                extra.append(ref)
            elif ff(l, r):
                ahead.append(ref)
            else:
                diverged.append(ref)
        elif mode == "pull":
            if l == b or l is None or ff(l, r):
                if r is None and ref == keep:
                    continue
                to_gitea.append((ref, r, l))
            elif r is None:
                extra.append(ref)
            elif ff(r, l):
                ahead.append(ref)
            else:
                diverged.append(ref)
        else:
            # Two-way: only fast-forwards, deletes only of what the other side left alone.
            if b is not None and l == b:
                if r is None and ref != keep:
                    to_gitea.append((ref, None, l))
                elif r is not None and (l is None or ff(l, r)):
                    to_gitea.append((ref, r, l))
                else:
                    diverged.append(ref)
            elif b is not None and r == b:
                if l is None:
                    to_remote.append((ref, None, r))
                elif r is None or ff(r, l):
                    to_remote.append((ref, l, r))
                else:
                    diverged.append(ref)
            elif l is None and b is None:
                to_gitea.append((ref, r, None))
            elif r is None and b is None:
                to_remote.append((ref, l, None))
            elif l is not None and r is not None and ff(l, r):
                to_gitea.append((ref, r, l))
            elif l is not None and r is not None and ff(r, l):
                to_remote.append((ref, l, r))
            else:
                diverged.append(ref)
    return to_remote, to_gitea, diverged, ahead, extra


def push(work, url, updates, env=None):
    """Pushes (ref, new or None, expected or None), each guarded by its lease; the refs that went."""
    if not updates:
        return set(), ""
    args = ["push", "--porcelain", "--no-verify"]
    for ref, _, expected in updates:
        args.append(f"--force-with-lease={ref}:{expected or ''}")
    args.append(url)
    args += [f"{new}:{ref}" if new else f":{ref}" for ref, new, _ in updates]
    code, out, err = git(*args, cwd=work, timeout=900, env=env)
    done, problems = set(), []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0] in (" ", "+", "-", "*", "="):
            done.add(parts[1].split(":")[-1])
        elif len(parts) >= 2 and parts[0] == "!":
            problems.append(f"{short(parts[1].split(':')[-1])}: {parts[2] if len(parts) > 2 else 'rejected'}")
    if code != 0 and not problems:
        problems.append(classify(err)[1])
    return done, "; ".join(problems)


def gitea_env():
    token = open(f"{os.environ['CREDENTIALS_DIRECTORY']}/token").read().strip()
    auth = base64.b64encode(f"{BOT}:{token}".encode()).decode()
    # In the environment, which only this user can read, not on the command line.
    return {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.extraHeader",
            "GIT_CONFIG_VALUE_0": f"Authorization: Basic {auth}"}


def fetch_gitea(work, repo):
    path = f"{REPOSITORIES}/{repo['owner']}/{repo['lower']}.git"
    code, _, err = git("fetch", "-q", "--prune", "--no-tags", path, *REFSPECS("g"), cwd=work)
    if code != 0:
        raise RuntimeError(f"cannot read the repository from gitea: {classify(err)[1]}")
    return refs(work, "g")


def signature(refs_map):
    return hashlib.sha256("\n".join(f"{k} {v}" for k, v in sorted(refs_map.items())).encode()).hexdigest()


def sync_link(repo, link, st, work, L, forced):
    """Runs one link; returns whether gitea changed."""
    url, mode = link["url"], link["mode"]
    h = link_id(url)
    # A new mode is a new start: push and two-way get the safety check again.
    if st.get("mode") != mode or st.get("checked") not in (None, mode):
        st["checked"] = None
    st.update(url=url, mode=mode, last_try=now())
    for key in ("lost", "diverged", "ahead", "extra"):
        st.setdefault(key, [])
    sig = signature(L)
    if (mode == "push" and not forced and st.get("checked") == mode and st.get("status") == "ok"
            and st.get("local") == sig and now() - st.get("remote_at", 0) < RECHECK):
        return False
    code, _, err = git("fetch", "-q", "--prune", "--no-tags", url, *REFSPECS(h), cwd=work, timeout=900)
    if code != 0:
        kind, text = classify(err)
        st.update(status="missing" if kind == "missing" else "error", kind=kind,
                  message=f"{'skipped, ' if kind == 'missing' else ''}{text}")
        return False
    st["remote_at"] = now()
    R = refs(work, h)
    # First run of push or two-way: nothing the remote has that gitea lacks may be lost.
    if mode in ("push", "two-way") and st.get("checked") != mode:
        lost = []
        for ref, r in sorted(R.items()):
            l = L.get(ref)
            if l == r:
                continue
            if l is None:
                lost.append({"ref": short(ref), "sha": r[:10], "why": "only on the remote"})
            elif not (ref.startswith("refs/heads/") and ancestor(work, r, l)):
                n = missing_count(work, r, l)
                lost.append({"ref": short(ref), "sha": r[:10],
                             "why": f"{n} commit{'s' if n != 1 else ''} gitea lacks" if n else "points elsewhere"})
        if lost:
            st.update(status="refused", kind="refused", lost=lost, diverged=[], ahead=[], extra=[],
                      message=f"refused: the remote has {len(lost)} branch{'es' if len(lost) != 1 else ''} or tags gitea lacks, which would be lost")
            return False
        st.update(checked=mode, base={}, lost=[])
    if mode == "pull":
        st["checked"] = "pull"
    B = st.get("base", {})
    to_remote, to_gitea, diverged, ahead, extra = plan(work, mode, L, R, B, repo["branch"])
    problems = []
    went, why = push(work, url, to_remote)
    if why:
        problems.append(f"to the remote: {why}")
    came, why2 = push(work, f"{GITEA}/{repo['owner']}/{repo['lower']}.git", to_gitea, gitea_env()) if to_gitea else (set(), "")
    if why2:
        problems.append(f"to gitea: {why2}")
    # The last state both sides agreed on, per ref.
    base = {ref: sha for ref, sha in L.items() if R.get(ref) == sha}
    for ref, new, _ in to_remote:
        if ref in went:
            base.pop(ref, None) if new is None else base.__setitem__(ref, new)
    for ref, new, _ in to_gitea:
        if ref in came:
            base.pop(ref, None) if new is None else base.__setitem__(ref, new)
    for ref in diverged + ahead + extra:
        if ref in B:
            base[ref] = B[ref]
    st.update(base=base, diverged=[short(r) for r in diverged], ahead=[short(r) for r in ahead],
              extra=[short(r) for r in extra], local=sig if not to_gitea else None)
    if problems:
        st.update(status="error", kind="push", message="; ".join(problems))
    elif diverged:
        st.update(status="diverged", kind="diverged",
                  message=f"diverged, left alone: {', '.join(short(r) for r in diverged)}")
    elif ahead:
        side = "the remote" if mode == "push" else "gitea"
        st.update(status="ahead", kind="ahead", message=f"{side} is ahead on {', '.join(short(r) for r in ahead)}, left alone")
    else:
        st.update(status="ok", kind="ok", message="in sync", last_sync=now())
    if st["status"] != "ok" and (went or came):
        st["last_sync"] = now()
    return bool(came)


def seed_namespaces():
    for owner, namespace in (read_json(SEED, {}) if SEED else {}).items():
        path = f"{CONFIG}/owners/{owner.lower()}.json"
        if namespace_ok(namespace) and not os.path.exists(path):
            write_json(path, {"namespace": namespace, "by": "config", "at": now()})


def auto_link(repos):
    """Repositories made by gitea's migration from a URL under some owner's namespace."""
    path = f"{STATE}/autolink.json"
    seen = read_json(path, None)
    if seen is None:
        write_json(path, {"since": now(), "seen": []}, 0o644)
        return
    namespaces = []
    for f in glob.glob(f"{CONFIG}/owners/*.json"):
        ns = read_json(f, {}).get("namespace")
        if ns and namespace_ok(ns):
            namespaces.append((ns, where(f"{ns}/x")))
    done = set(seen["seen"])
    for repo in repos.values():
        if repo["created"] < seen["since"] or repo["id"] in done or not repo["original"]:
            continue
        done.add(repo["id"])
        origin = where(repo["original"])
        if blocked(repo) or not origin or os.path.exists(f"{CONFIG}/links/{repo['id']}.json"):
            continue
        for ns, (host, ns_path) in namespaces:
            ns_path = ns_path.removesuffix("/x")
            rest = origin[1][len(ns_path) + 1:]
            if origin[0] == host and origin[1].lower().startswith(ns_path.lower() + "/") and rest and "/" not in rest:
                write_json(f"{CONFIG}/links/{repo['id']}.json", {
                    "owner": repo["owner"], "repo": repo["lower"],
                    "links": [{"url": target_for(ns, rest), "mode": "push", "by": "migration", "added": now()}]})
                print(f"{repo['owner']}/{repo['lower']}: linked to {target_for(ns, rest)} after its migration")
                break
    write_json(path, {"since": seen["since"], "seen": sorted(done)}, 0o644)


def public_label(repo, links, states):
    out = []
    for link in links:
        st = states.get(link_id(link["url"]), {})
        _, host, _, path = parse_ssh(link["url"])
        out.append({"host": host, "path": path.removesuffix(".git"), "mode": link["mode"],
                    "state": "ok" if st.get("status") == "ok" else "warn",
                    "note": st.get("message", "waiting for the first sync"), "when": st.get("last_sync")})
    return {"links": out}


def sync():
    setup()
    seed_namespaces()
    repos = {r["id"]: r for r in repo_rows()}
    auto_link(repos)
    first = []
    for path in glob.glob(f"{CONFIG}/spool/sync/*"):
        try:
            os.remove(path)
            first.append(int(os.path.basename(path)))
        except (FileNotFoundError, ValueError):
            pass
    ids = []
    for path in glob.glob(f"{CONFIG}/links/*.json"):
        try:
            ids.append(int(os.path.basename(path)[:-5]))
        except ValueError:
            pass
    ids.sort(key=lambda i: (i not in first, i))
    labels, report = {}, []
    for repo_id in ids:
        repo = repos.get(repo_id)
        links = [l for l in links_of(repo_id) if parse_ssh(l.get("url")) and l.get("mode") in ("push", "pull", "two-way")]
        state_path = f"{STATE}/links/{repo_id}.json"
        work = f"{STATE}/work/{repo_id}.git"
        if repo is None and repos:
            # Gone from gitea: its links go with it.
            for p in (f"{CONFIG}/links/{repo_id}.json", state_path):
                if os.path.exists(p):
                    os.remove(p)
            shutil.rmtree(work, ignore_errors=True)
        if repo is None:
            continue
        states = read_json(state_path, {})
        states = {h: s for h, s in states.items() if h in {link_id(l["url"]) for l in links}}
        name = f"{repo['owner']}/{repo['lower']}"
        why = blocked(repo)
        if why or repo["status"] != 0:
            for link in links:
                st = states.setdefault(link_id(link["url"]), {"url": link["url"], "mode": link["mode"]})
                st.update(status="blocked", kind="blocked",
                          message=f"not mirrored: {', '.join(why)}" if why else "waiting for gitea to finish the repository")
            write_json(state_path, states, 0o644)
            report.append(f"{name}: {'blocked' if why else 'waiting'}")
            continue
        if not os.path.isdir(work):
            git("init", "-q", "--bare", work)
        try:
            L = fetch_gitea(work, repo)
        except RuntimeError as e:
            for link in links:
                states.setdefault(link_id(link["url"]), {"url": link["url"]}).update(status="error", kind="gitea", message=str(e))
            write_json(state_path, states, 0o644)
            report.append(f"{name}: {e}")
            continue
        # Copies of remotes no longer linked go.
        known = {link_id(l["url"]) for l in links}
        for ref_ns in {line.split("/")[2] for line in git("for-each-ref", "--format=%(refname)", "refs/m/", cwd=work)[1].split()}:
            if ref_ns != "g" and ref_ns not in known:
                stale = git("for-each-ref", "--format=delete %(refname)", f"refs/m/{ref_ns}/", cwd=work)[1]
                subprocess.run(["git", "update-ref", "--stdin"], input=stale, text=True, cwd=work)
        for link in links:
            st = states.setdefault(link_id(link["url"]), {})
            before = (st.get("status"), st.get("message"))
            stop = mode_blocked(repo, link["mode"])
            if stop:
                st.update(url=link["url"], mode=link["mode"], status="blocked", kind="blocked", message=stop)
            else:
                try:
                    if sync_link(repo, link, st, work, L, repo_id in first):
                        L = fetch_gitea(work, repo)
                except Exception as e:
                    st.update(status="error", kind="error", message=f"failed: {e}")
            report.append(f"{name} -> {link['url']} ({link['mode']}): {st.get('status')}, {st.get('message')}")
            # The journal gets changes only, not the same state every 30 seconds.
            if (st.get("status"), st.get("message")) != before:
                print(report[-1])
        write_json(state_path, states, 0o644)
        if links:
            labels[(repo["owner"], repo["lower"])] = public_label(repo, links, states)
    # Labels for public repositories only, replaced as a whole.
    wanted = set()
    for (owner, lower), label in labels.items():
        wanted.add(f"{STATE}/public/{owner}/{lower}.json")
        write_json(f"{STATE}/public/{owner}/{lower}.json", label, 0o644)
    write_json(f"{STATE}/public/none.json", {}, 0o644)
    for path in glob.glob(f"{STATE}/public/*/*.json"):
        if path not in wanted:
            os.remove(path)
    for path in glob.glob(f"{STATE}/work/*.git"):
        if int(os.path.basename(path)[:-4]) not in ids:
            shutil.rmtree(path, ignore_errors=True)
    with open(f"{STATE}/report.txt.new", "w") as f:
        f.write(f"at {time.strftime('%Y-%m-%d %H:%M:%S')}\n" + "".join(line + "\n" for line in report))
    os.replace(f"{STATE}/report.txt.new", f"{STATE}/report.txt")


if __name__ == "__main__":
    os.makedirs(STATE, exist_ok=True)
    with open(f"{STATE}/.lock-{sys.argv[1]}", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        {"sync": sync, "probe": probe}[sys.argv[1]]()
