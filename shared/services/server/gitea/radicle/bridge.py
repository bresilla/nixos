"""Two-way bridge between gitea and Radicle for every published repository.

Run by radicle-sync, out of band: gitea never waits on it. What a gitea user does goes
to Radicle signed by their own key when gitea holds one, otherwise by this node with
their name; every exported item ends in a "— user on host" line, which also marks it as
an echo. Radicle items by a held key appear in gitea as that user (the bot's sudo),
others as the bot with the author's DID. Fast-forwards from held keys of users who may
write to a repository are pushed into gitea.
"""
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

DATABASE = os.environ["DATABASE"]
STATE = os.environ["SYNC_STATE"]
STORAGE = os.environ["RAD_STATE"] + "/storage"
GITEA = os.environ.get("GITEA_URL", "http://127.0.0.1:3000")
ORIGIN = os.environ["ORIGIN"]
HOST = ORIGIN.split("://", 1)[-1]
BOT = os.environ["BOT"].lower()
TOKEN = open(os.environ["CREDENTIALS_DIRECTORY"] + "/token").read().strip()
NID = sys.argv[1]
MODE = sys.argv[2] if len(sys.argv) > 2 else "all"
PATCH_BRANCH = "rad/patch/"
ISSUE, PATCH = "xyz.radicle.issue", "xyz.radicle.patch"
WRITERS = ("write", "admin", "owner")
RAD_MARK = re.compile(r"<!-- radicle:(issue|patch|comment):([0-9a-f]{40}) -->")
# Radicle drops HTML comments from messages, so its side carries a visible last line.
GITEA_MARK = re.compile(rf"^— \S+ on {re.escape(HOST)}, (issue|pull|comment) (\d+)\b", re.M)

# Keys gitea holds, by Node ID; the homes rad runs in for each signer.
KEYS = json.load(open(os.environ["KEYS_FILE"]))
HOMES = {NID: os.environ["RAD_HOME"], **{k: v["home"] for k, v in KEYS.items()}}
KEY_OF = {v["user"]: k for k, v in KEYS.items() if v["current"]}


def short(nid):
    nid = nid.removeprefix("did:key:")
    return f"{nid[:8]}…{nid[-4:]}"


def marks(pattern, text, kind):
    return {m.group(2) for m in pattern.finditer(text or "") if m.group(1) == kind}


def echo(author, body):
    """Written by this bridge: by a key it holds, with the gitea line."""
    return author in HOMES and GITEA_MARK.search(body or "") is not None


def run(*args, by=None):
    env = None
    if by:
        env = {**os.environ, "RAD_HOME": HOMES[by], "HOME": HOMES[by]}
    return subprocess.run(args, env=env, check=True, capture_output=True, text=True).stdout


def gitea(method, path, body=None, sudo=None):
    headers = {"Authorization": f"token {TOKEN}", "Content-Type": "application/json"}
    if sudo:
        headers["Sudo"] = sudo
    request = urllib.request.Request(f"{GITEA}/api/v1{path}", method=method, headers=headers,
                                     data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read() or b"null")
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path}: {e.code} {e.read()[:200]!r}") from None


def git_push(storage, owner, repo, refspec):
    """Pushes from Radicle's storage into gitea over HTTP as the bot."""
    env = {**os.environ, "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.extraHeader",
           "GIT_CONFIG_VALUE_0": f"Authorization: token {TOKEN}", "GIT_TERMINAL_PROMPT": "0"}
    subprocess.run(["git", "-C", storage, "push", "-q", f"{GITEA}/{owner}/{repo}.git", refspec],
                   env=env, check=True, capture_output=True, text=True)


class Repo:
    def __init__(self, row, rid, signer):
        self.id, self.owner, self.lower, self.mirror, self.branch = row
        self.rid, self.signer = rid, signer
        self.name = f"{self.owner}/{self.lower}"
        self.storage = f"{STORAGE}/{rid.removeprefix('rad:')}"
        self.api = f"/repos/{self.owner}/{self.lower}"
        self.gitea = f"{os.environ['REPOSITORIES']}/{self.owner}/{self.lower}.git"
        self.path = f"{STATE}/bridge/{self.id}.json"
        self.announce = False
        self.cobs = {}
        self.writers = {}

    def rad(self, *args, by=None):
        self.announce = True
        return run("rad", *args, "--repo", self.rid, "--no-announce", by=by or self.signer)

    def show(self, kind, oid, fresh=False):
        if fresh or (kind, oid) not in self.cobs:
            out = run("rad", "cob", "show", "--repo", self.rid, "--type", kind, "--object", oid)
            self.cobs[kind, oid] = json.loads(out)
        return self.cobs[kind, oid]

    def may_write(self, user):
        if user not in self.writers:
            found = gitea("GET", f"{self.api}/collaborators/{urllib.parse.quote(user)}/permission")
            self.writers[user] = found.get("permission") in WRITERS
        return self.writers[user]

    def log(self, text):
        print(f"{self.name}: {text}", flush=True)


def published(db):
    """Repositories the sync has published, with their Radicle IDs and signers."""
    found = []
    for entry in sorted(os.listdir(f"{STATE}/repos")):
        d = f"{STATE}/repos/{entry}"
        if not entry.isdigit() or os.path.exists(f"{d}/withdrawn") or not os.path.exists(f"{d}/rid"):
            continue
        row = db.execute("select id, lower(owner_name), lower_name, is_mirror, default_branch "
                         "from repository where id = ?", (int(entry),)).fetchone()
        signer = open(f"{d}/signer").read().strip() if os.path.exists(f"{d}/signer") else NID
        if row and signer in HOMES:
            found.append(Repo(row, open(f"{d}/rid").read().strip(), signer))
    return found


def gitea_items(db, repo):
    """Issues and pull requests with their labels and heads, and a fingerprint of each."""
    heads = {}
    for line in run("git", "-C", repo.gitea, "for-each-ref", "--format=%(objectname) %(refname)",
                    "refs/pull").splitlines():
        oid, ref = line.split(" ", 1)
        if ref.endswith("/head"):
            heads[ref.split("/")[2]] = oid
    items = {}
    for row in db.execute(
            'select i.id, i."index", lower(coalesce(u.name, \'\')), coalesce(u.name, \'ghost\'), i.name, '
            "coalesce(i.content, ''), i.is_closed, i.is_pull, i.updated_unix, coalesce(p.has_merged, 0), "
            "coalesce(p.merged_commit_id, ''), coalesce(p.base_branch, ''), "
            "(select max(id) from comment c where c.issue_id = i.id), "
            "(select group_concat(l.name, char(10)) from issue_label il join label l on l.id = il.label_id "
            "where il.issue_id = i.id) from issue i left join user u on u.id = i.poster_id "
            "left join pull_request p on p.issue_id = i.id where i.repo_id = ?", (repo.id,)):
        iid, number, poster, user, title, body, closed, pull, updated, merged, commit, base, last, labels = row
        state = "merged" if merged else "closed" if closed else "open"
        labels = sorted({re.sub(r"\s+", "-", n.strip()) for n in (labels or "").split("\n") if n.strip()})
        head = heads.get(str(number), "")
        items[number] = {"id": iid, "number": number, "poster": poster, "user": user, "title": title,
                         "body": body, "state": state, "pull": bool(pull), "commit": commit,
                         "base": base, "head": head, "labels": labels,
                         "fp": f"{updated}:{state}:{last}:{head}:{','.join(labels)}"}
    return items


def gitea_comments(db, item):
    return [{"id": str(c[0]), "poster": c[1], "user": c[2], "body": c[3]} for c in db.execute(
        "select c.id, lower(coalesce(u.name, '')), coalesce(u.name, 'ghost'), coalesce(c.content, '') "
        "from comment c left join user u on u.id = c.poster_id "
        "where c.issue_id = ? and c.type = 0 order by c.id", (item["id"],))]


def rad_comments(discussion, skip=None):
    out = []
    for cid in discussion.get("timeline", []):
        c = discussion["comments"].get(cid)
        if c and cid != skip:
            stamp = c["edits"][0]["timestamp"] if c.get("edits") else 0
            out.append({"id": cid, "author": c["author"], "body": c["body"], "at": stamp})
    return out


def as_gitea(nid, body, mark):
    """Who posts a Radicle item in gitea: the user its key belongs to, or the bot."""
    key = KEYS.get(nid)
    if key:
        return key["name"], f"{body}\n\n<sub>On Radicle</sub>\n{mark}"
    return None, f"{body}\n\n<sub>did:key:{nid} on Radicle</sub>\n{mark}"


def sync_comments(repo, number, ours, theirs, post_rad):
    """Comments both ways; echoes are known by their markers."""
    imported = {cid for c in theirs for cid in marks(RAD_MARK, c["body"], "comment")}
    exported = set().union(*(marks(GITEA_MARK, c["body"], "comment") for c in ours if c["author"] in HOMES))
    for c in ours:
        if c["id"] in imported or echo(c["author"], c["body"]):
            continue
        sudo, body = as_gitea(c["author"], c["body"], f"<!-- radicle:comment:{c['id']} -->")
        gitea("POST", f"{repo.api}/issues/{number}/comments", sudo=sudo, body={"body": body})
        repo.log(f"comment {c['id'][:7]} to #{number} as {sudo or BOT}")
    for c in theirs:
        if c["poster"] == BOT or c["id"] in exported or RAD_MARK.search(c["body"]):
            continue
        post_rad(f"{c['body']}\n\n— {c['user']} on {HOST}, comment {c['id']}", KEY_OF.get(c["poster"], NID))
        repo.log(f"comment {c['id']} from #{number}")


def sync_labels(repo, kind, oid, cob, item):
    """Labels follow gitea's; Radicle lets only delegates set them."""
    have, want = set(cob.get("labels", [])), set(item["labels"])
    if have == want:
        return
    args = [a for name in sorted(want - have) for a in ("--add", name)]
    args += [a for name in sorted(have - want) for a in ("--delete", name)]
    repo.rad(kind, "label", oid, *args, "-q")
    repo.log(f"{kind} {oid[:7]} labels: {', '.join(sorted(want)) or 'none'}")


def set_gitea_state(repo, number, state, pull=False):
    gitea("PATCH", f"{repo.api}/{'pulls' if pull else 'issues'}/{number}", {"state": state})


def sync_issue(db, repo, rid, item, entry):
    issue = repo.show(ISSUE, rid)
    rs = "open" if issue["state"]["status"] == "open" else "closed"
    if rs != entry["rad"]:
        if rs != item["state"]:
            set_gitea_state(repo, item["number"], rs)
            repo.log(f"issue #{item['number']} {rs} from Radicle")
    elif item["state"] != entry["gitea"] and item["state"] != rs:
        repo.rad("issue", "state", rid, "--open" if item["state"] == "open" else "--closed", "-q")
        repo.log(f"issue {rid[:7]} {item['state']} from gitea")
        rs = item["state"]
    entry["rad"] = entry["gitea"] = rs
    sync_labels(repo, "issue", rid, issue, item)
    root = issue["thread"]["timeline"][0] if issue["thread"]["timeline"] else None
    sync_comments(repo, item["number"], rad_comments(issue["thread"], skip=root),
                  gitea_comments(db, item),
                  lambda body, by: repo.rad("issue", "comment", rid, "-m", body, "-q", by=by))


def latest(patch):
    return max((r for r in patch["revisions"].values() if r), key=lambda r: r["timestamp"])


def patch_state(patch):
    status = patch["state"]["status"]
    return "open" if status == "draft" else status


def author_of(cob, kind):
    if kind == PATCH:
        return cob["author"]["id"].removeprefix("did:key:")
    timeline = cob["thread"]["timeline"]
    return cob["thread"]["comments"][timeline[0]]["author"] if timeline else NID


def opening(cob, kind):
    if kind == PATCH:
        first = cob["revisions"].get(cob["timeline"][0]) or {}
        return (first.get("description") or [{}])[-1].get("body", "")
    timeline = cob["thread"]["timeline"]
    return cob["thread"]["comments"][timeline[0]]["body"] if timeline else ""


def push_patch(repo, pid, oid):
    git_push(repo.storage, repo.owner, repo.lower, f"+{oid}:refs/heads/{PATCH_BRANCH}{pid[:7]}")


def rad_push(repo, refspec, message, by):
    """Pushes from gitea's repository to a signer's copy, through git-remote-rad."""
    env = {**os.environ, "RAD_HOME": HOMES[by], "HOME": HOMES[by]}
    return subprocess.run(["git", "-C", repo.gitea, "push", "-o", f"patch.message={message}",
                           f"rad://{repo.rid.removeprefix('rad:')}/{by}", refspec],
                          env=env, check=True, capture_output=True, text=True).stderr


def in_default(repo, commit):
    """True once the merge commit is in the signer's published default branch."""
    ref = f"refs/namespaces/{repo.signer}/refs/heads/{repo.branch}"
    return subprocess.run(["git", "-C", repo.storage, "merge-base", "--is-ancestor", commit, ref],
                          capture_output=True).returncode == 0


def mark_merged(repo, pid, patch, commit):
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        json.dump({"type": "merge", "revision": latest(patch)["id"], "commit": commit}, f)
    os.chmod(f.name, 0o644)
    try:
        run("rad", "cob", "update", "--repo", repo.rid, "--type", PATCH, "--object", pid,
            "--message", "Merged in gitea", f.name, by=repo.signer)
        repo.announce = True
    finally:
        os.unlink(f.name)


def sync_patch(db, repo, pid, item, entry):
    patch = repo.show(PATCH, pid)
    rev = latest(patch)
    rs, gs = patch_state(patch), item["state"]
    mine = entry.get("origin") == "gitea"
    if mine and rs == "open" and gs == "open" and item["head"] and item["head"] != entry["head"]:
        by = entry.get("by", NID)
        rad_push(repo, f"+{item['head']}:refs/heads/patches/{pid}", f"New commits on {HOST}", by)
        repo.announce = True
        entry["head"] = item["head"]
        repo.log(f"pull #{item['number']} head {item['head'][:7]} to patch {pid[:7]}")
        patch = repo.show(PATCH, pid, fresh=True)
    elif not mine and rs == "open" and gs == "open" and rev["oid"] != entry["head"]:
        push_patch(repo, pid, rev["oid"])
        gitea("POST", f"{repo.api}/issues/{item['number']}/comments", {
            "body": f"New revision `{rev['id'][:7]}` on Radicle, head `{rev['oid'][:7]}`."})
        entry["head"] = rev["oid"]
        repo.log(f"patch {pid[:7]} revision {rev['id'][:7]} to #{item['number']}")
    if not mine and patch["title"] != entry.get("title") and gs == "open":
        gitea("PATCH", f"{repo.api}/pulls/{item['number']}", {"title": patch["title"]})
        entry["title"] = patch["title"]
    entry.pop("pending", None)
    if rs != entry["rad"]:
        want = "open" if rs == "open" else "closed"
        if gs != "merged" and gs != want:
            set_gitea_state(repo, item["number"], want, pull=True)
            repo.log(f"pull #{item['number']} {want}: patch {rs} on Radicle")
            gs = want
    elif gs != entry["gitea"]:
        if gs == "closed" and rs == "open":
            repo.rad("patch", "archive", pid, "-q")
            rs = "archived"
        elif gs == "open" and rs == "archived":
            repo.rad("patch", "archive", pid, "--undo", "-q")
            rs = "open"
        elif gs == "merged" and rs != "merged":
            if not in_default(repo, item["commit"]):
                entry["pending"] = True
                return
            mark_merged(repo, pid, patch, item["commit"])
            rs = "merged"
        repo.log(f"patch {pid[:7]} {rs}: pull #{item['number']} {gs} in gitea")
    entry["rad"], entry["gitea"] = rs, gs
    sync_labels(repo, "patch", pid, patch, item)
    comments = [c for r in patch["revisions"].values() if r for c in rad_comments(r["discussion"])]
    sync_comments(repo, item["number"], sorted(comments, key=lambda c: c["at"]),
                  gitea_comments(db, item),
                  lambda body, by: repo.rad("patch", "comment", latest(patch)["id"], "-m", body, "-q", by=by))


def open_from_radicle(repo, rid):
    issue = repo.show(ISSUE, rid)
    sudo, body = as_gitea(author_of(issue, ISSUE), opening(issue, ISSUE), f"<!-- radicle:issue:{rid} -->")
    created = gitea("POST", f"{repo.api}/issues", sudo=sudo, body={"title": issue["title"], "body": body})
    repo.log(f"issue {rid[:7]} opened as #{created['number']} by {sudo or BOT}")
    return created["number"]


def open_from_gitea(repo, item):
    url = f"{ORIGIN}/{repo.owner}/{repo.lower}/issues/{item['number']}"
    out = repo.rad("issue", "open", "--title", item["title"], "--description",
                   f"{item['body']}\n\n— {item['user']} on {HOST}, issue {item['number']}: {url}",
                   by=KEY_OF.get(item["poster"], NID))
    found = re.search(r"Issue\s+([0-9a-f]{40})", out)
    if not found:
        raise RuntimeError(f"no issue ID from rad issue open for #{item['number']}")
    repo.log(f"issue #{item['number']} opened as {found.group(1)[:7]}")
    return found.group(1)


def open_pull(repo, pid):
    patch = repo.show(PATCH, pid)
    rev = latest(patch)
    push_patch(repo, pid, rev["oid"])
    sudo, body = as_gitea(author_of(patch, PATCH), opening(patch, PATCH),
                          f"`rad patch checkout {pid[:7]}`\n<!-- radicle:patch:{pid} -->")
    # Opening a pull request from a branch of the repository itself needs write access.
    if sudo and not repo.may_write(sudo.lower()):
        sudo, body = None, f"{body}\n\n<sub>by {sudo}</sub>"
    created = gitea("POST", f"{repo.api}/pulls", sudo=sudo, body={
        "head": f"{PATCH_BRANCH}{pid[:7]}", "base": repo.branch, "title": patch["title"], "body": body})
    repo.log(f"patch {pid[:7]} opened as #{created['number']} by {sudo or BOT}")
    return {"number": created["number"], "head": rev["oid"], "title": patch["title"],
            "rad": "open", "gitea": "open"}


def open_patch(repo, item):
    """A gitea pull request as a patch, by the poster's key or this node's."""
    by = KEY_OF.get(item["poster"], NID)
    out = rad_push(repo, f"{item['head']}:refs/patches", item["title"], by)
    found = re.search(r"Patch ([0-9a-f]{40}) opened", out)
    if not found:
        raise RuntimeError(f"no patch ID from git-remote-rad for #{item['number']}")
    pid = found.group(1)
    url = f"{ORIGIN}/{repo.owner}/{repo.lower}/pulls/{item['number']}"
    repo.rad("patch", "edit", pid, "-m", item["title"],
             "-m", f"{item['body']}\n\n— {item['user']} on {HOST}, pull {item['number']}: {url}".lstrip(), by=by)
    repo.log(f"pull #{item['number']} opened as patch {pid[:7]}")
    return pid, {"number": item["number"], "origin": "gitea", "by": by, "head": item["head"],
                 "rad": "open", "gitea": "open"}


def rebuild(repo, items, cob_ids):
    """The mapping from the markers both sides carry, for a lost or new state."""
    state = {"issues": {}, "patches": {}}
    for item in items.values():
        for kind, entries in (("issue", state["issues"]), ("patch", state["patches"])):
            for oid in marks(RAD_MARK, item["body"], kind):
                entries[oid] = {"number": item["number"]}
    for kind, oid in cob_ids:
        cob = repo.show(kind, oid)
        entries = state["issues"] if kind == ISSUE else state["patches"]
        if oid in entries or not echo(author_of(cob, kind), opening(cob, kind)):
            continue
        for number in marks(GITEA_MARK, opening(cob, kind), "issue" if kind == ISSUE else "pull"):
            entries[oid] = {"number": int(number)}
            if kind == PATCH:
                entries[oid].update(origin="gitea", by=author_of(cob, kind))
    for kind, entries in ((ISSUE, state["issues"]), (PATCH, state["patches"])):
        for oid, entry in list(entries.items()):
            item = items.get(entry["number"])
            if not item or (kind, oid) not in cob_ids:
                del entries[oid]
                continue
            cob = repo.show(kind, oid)
            if kind == ISSUE:
                entry["rad"] = "open" if cob["state"]["status"] == "open" else "closed"
            else:
                entry.update(rad=patch_state(cob), head=item["head"] if entry.get("origin") else latest(cob)["oid"])
                if not entry.get("origin"):
                    entry["title"] = cob["title"]
            entry["gitea"] = item["state"]
    return state


def bridge(db, repo, units, refs):
    try:
        state = json.load(open(repo.path))
        fresh = False
    except (FileNotFoundError, json.JSONDecodeError):
        state, fresh = None, True
    cobs = {}
    for oid, ref in refs:
        parts = ref.split("/")
        if len(parts) == 7 and parts[4] == "cobs" and parts[5] in (ISSUE, PATCH):
            cobs.setdefault((parts[5], parts[6]), []).append(oid)
    digests = {f"{k}/{o}": hashlib.sha256(" ".join(sorted(v)).encode()).hexdigest()
               for (k, o), v in cobs.items()}
    items = gitea_items(db, repo)
    if fresh:
        state = rebuild(repo, items, cobs.keys())
    seen_rad, seen_gitea = state.setdefault("rad", {}), state.setdefault("gitea", {})
    before = {str(n): i["fp"] for n, i in items.items()}
    by_number = {e["number"]: oid for oid, e in {**state["issues"], **state["patches"]}.items()}

    def changed(kind, oid, number):
        return (digests.get(f"{kind}/{oid}") != seen_rad.get(f"{kind}/{oid}")
                or (number is not None and items[number]["fp"] != seen_gitea.get(str(number))))

    issues_on = 2 in units
    pulls_on = 3 in units and not repo.mirror
    for kind, oid in sorted(cobs):
        entries = state["issues"] if kind == ISSUE else state["patches"]
        entry = entries.get(oid)
        if entry and entry["number"] not in items:
            continue
        if not changed(kind, oid, entry and entry["number"]) and not (entry or {}).get("pending"):
            continue
        if kind == ISSUE and issues_on:
            if entry:
                sync_issue(db, repo, oid, items[entry["number"]], entry)
            else:
                issue = repo.show(ISSUE, oid)
                if issue["state"]["status"] == "open" and not echo(author_of(issue, ISSUE), opening(issue, ISSUE)):
                    number = open_from_radicle(repo, oid)
                    entries[oid] = {"number": number, "rad": "open", "gitea": "open"}
                    items = gitea_items(db, repo)
                    sync_issue(db, repo, oid, items[number], entries[oid])
        elif kind == PATCH and pulls_on:
            if entry:
                sync_patch(db, repo, oid, items[entry["number"]], entry)
            else:
                patch = repo.show(PATCH, oid)
                if patch_state(patch) == "open" and not echo(author_of(patch, PATCH), opening(patch, PATCH)):
                    entries[oid] = open_pull(repo, oid)
                    items = gitea_items(db, repo)
                    sync_patch(db, repo, oid, items[entries[oid]["number"]], entries[oid])
        seen_rad[f"{kind}/{oid}"] = digests.get(f"{kind}/{oid}")
        save(repo.path, state)
    # Gitea's own issues and pull requests; patches only against the default branch.
    for number, item in sorted(items.items()):
        if number in by_number or item["poster"] == BOT or item["state"] != "open":
            continue
        if item["fp"] == seen_gitea.get(str(number)) or RAD_MARK.search(item["body"]):
            continue
        if item["pull"] and pulls_on and item["head"] and item["base"] == repo.branch:
            oid, entry = open_patch(repo, item)
            state["patches"][oid] = entry
            sync_patch(db, repo, oid, item, entry)
        elif not item["pull"] and issues_on:
            oid = open_from_gitea(repo, item)
            state["issues"][oid] = {"number": number, "rad": "open", "gitea": "open"}
            sync_issue(db, repo, oid, item, state["issues"][oid])
        save(repo.path, state)
    # Taken before this pass: its own writes show up once more, as no-ops.
    state["gitea"] = before
    save(repo.path, state)


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(f"{path}.tmp", "w") as f:
        json.dump(data, f)
    os.replace(f"{path}.tmp", path)


def fast_forwards(repo, refs):
    """Branches a held key moved ahead of gitea's go into gitea, if its user may write."""
    try:
        tried = json.load(open(f"{repo.path}.pushed"))
    except (FileNotFoundError, json.JSONDecodeError):
        tried = {}
    for oid, ref in refs:
        parts = ref.split("/", 5)
        key = KEYS.get(parts[2]) if len(parts) == 6 else None
        if not key or not key["current"] or parts[3:5] != ["refs", "heads"]:
            continue
        branch, seen = parts[5], f"{parts[2]}/{parts[5]}"
        if branch.startswith((PATCH_BRANCH, "patches/")) or tried.get(seen) == oid:
            continue
        tip = subprocess.run(["git", "-C", repo.gitea, "rev-parse", "-q", "--verify",
                              f"refs/heads/{branch}^{{commit}}"], capture_output=True, text=True)
        if tip.returncode != 0 or tip.stdout.strip() == oid:
            continue
        ancestor = subprocess.run(["git", "-C", repo.storage, "merge-base", "--is-ancestor",
                                   tip.stdout.strip(), oid], capture_output=True)
        if ancestor.returncode != 0 or not repo.may_write(key["user"]):
            continue
        tried[seen] = oid
        try:
            git_push(repo.storage, repo.owner, repo.lower, f"{oid}:refs/heads/{branch}")
            repo.log(f"{branch} fast-forwarded to {oid[:7]} by {key['name']}")
        except subprocess.CalledProcessError as e:
            repo.log(f"{branch} from {key['name']} refused: {e.stderr.strip()[:200]}")
    save(f"{repo.path}.pushed", tried)


def follow():
    """Held keys are followed under their user's name, so their refs are always fetched."""
    path = f"{STATE}/bridge/followed.json"
    try:
        before = set(json.load(open(path)))
    except (FileNotFoundError, json.JSONDecodeError):
        before = set()
    now = {k for k, v in KEYS.items() if v["current"]}
    for nid in sorted(now - before):
        run("rad", "follow", f"did:key:{nid}", "--alias", KEYS[nid]["name"])
    for nid in sorted(before - now):
        run("rad", "unfollow", f"did:key:{nid}")
    save(path, sorted(now))


def publish_keys():
    """Each user's Radicle ID, for their profile page."""
    out = f"{STATE}/users"
    os.makedirs(out, exist_ok=True)
    wanted = {f"{user}.json": {"dids": [f"did:key:{nid}"]} for user, nid in KEY_OF.items()}
    wanted["none.json"] = {}
    for name in os.listdir(out):
        if name not in wanted:
            os.unlink(f"{out}/{name}")
    for name, data in wanted.items():
        save(f"{out}/{name}", data)


def main():
    os.makedirs(f"{STATE}/bridge", exist_ok=True)
    failed = False
    with sqlite3.connect(f"file:{DATABASE}?mode=ro", uri=True, timeout=5) as db:
        if MODE == "all":
            publish_keys()
            follow()
        for repo in published(db):
            try:
                refs = [tuple(line.split(" ", 1)) for line in run(
                    "git", "-C", repo.storage, "for-each-ref", "--format=%(objectname) %(refname)",
                    "refs/namespaces").splitlines()]
                if MODE == "pushes":
                    if not repo.mirror:
                        fast_forwards(repo, refs)
                    continue
                units = {u for (u,) in db.execute("select type from repo_unit where repo_id = ?", (repo.id,))}
                bridge(db, repo, units, refs)
            except (subprocess.CalledProcessError, RuntimeError, OSError, KeyError) as e:
                detail = e.stderr.strip()[:300] if isinstance(e, subprocess.CalledProcessError) else e
                print(f"{repo.name}: bridge failed: {detail}", file=sys.stderr, flush=True)
                failed = True
            if repo.announce:
                subprocess.run(["rad", "sync", repo.rid, "--announce", "--timeout", "10"],
                               capture_output=True)
    sys.exit(1 if failed else 0)


main()
