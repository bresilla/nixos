set -euo pipefail

# The main node's home: its storage and sockets, the key from the credential.
home=$RUNTIME_DIRECTORY/home
mkdir -p "$home/keys" "$RAD_STATE"/{storage,node,cobs}
for d in storage node cobs; do ln -sfn "$RAD_STATE/$d" "$home/$d"; done
ln -sfn "$RAD_CONFIG" "$home/config.json"
install -m 0600 "$CREDENTIALS_DIRECTORY/key" "$home/keys/radicle"
ssh-keygen -y -f "$home/keys/radicle" > "$home/keys/radicle.pub"

# Every node by the gitea user it signs for: the main one, then each user's own, with
# its own key and storage. Gitea owns the repositories; git-remote-rad's libgit2 reads
# only the config file, not -c.
declare -A home_of nid_of recovery_of
order=()
known='{}'
while IFS=$'\t' read -r user h rec; do
  user=${user,,}
  [ "$h" != - ] || h=$home
  if [ ! -s "$h/keys/radicle" ]; then echo "$user: node has no key yet" >&2; continue; fi
  printf '[safe]\n\tdirectory = *\n' > "$h/.gitconfig"
  n=$(RAD_HOME=$h HOME=$h rad self --did | sed 's/^did:key://')
  home_of[$user]=$h nid_of[$user]=$n recovery_of[$user]=$rec
  order+=("$user")
  known=$(printf '%s' "$known" | jq --arg n "$n" --arg u "$user" --arg h "$h" '.[$n] = {user: $u, home: $h}')
done < <(jq -r '.[] | [.user, (if .home == "" then "-" else .home end), (.recovery | join(" "))] | @tsv' "$NODES")
printf '%s' "$known" > "$RUNTIME_DIRECTORY/nodes.json"
export RAD_HOME=$home HOME=$home

# rad and git in the repository's node.
r() { RAD_HOME=${home_of[$who]} HOME=${home_of[$who]} "$@"; }

# Sets who to the node a repository goes out from: its owner's, or for an organisation
# the first node (the main one first) whose user is in its owners team; none means
# it stays unpublished.
declare -A node_for
node_of() {
  local u owners
  if [ -z "${node_for[$1]+set}" ]; then
    node_for[$1]=""
    if [ -n "${home_of[$1]:-}" ]; then
      node_for[$1]=$1
    else
      owners=$(sqlite3 -cmd '.timeout 5000' "file:$DATABASE?mode=ro" "select m.lower_name from user o
        join team t on t.org_id = o.id and t.lower_name = 'owners' join team_user tu on tu.team_id = t.id
        join user m on m.id = tu.uid where o.lower_name = '$1' and o.type = 1")
      for u in "${order[@]}"; do
        if grep -qx "$u" <<< "$owners"; then node_for[$1]=$u; break; fi
      done
    fi
  fi
  who=${node_for[$1]}
}

repos="$SYNC_STATE/repos"
out="$SYNC_STATE/public.new"
rm -rf "$out"
mkdir -p "$repos" "$out"
echo '{}' > "$out/none.json"

# Owner visibility 0 is public; a private or limited owner hides its repositories.
query="select r.id, lower(r.owner_name) as owner, r.lower_name as lower, r.name,
  coalesce(r.description, '') as description, coalesce(r.default_branch, '') as branch,
  coalesce(r.topics, '[]') as topics, coalesce(r.website, '') as website, r.is_mirror as mirror,
  (r.is_private = 0 and r.is_empty = 0 and u.visibility = 0) as public
  from repository r join user u on u.id = r.owner_id"
listing=$(sqlite3 -json -cmd '.timeout 5000' "file:$DATABASE?mode=ro" "$query")
[ -n "$listing" ] || listing='[]'

# Creates the Radicle repository from a throwaway clone, the only step that needs a work tree.
publish() {
  local tmp
  tmp=$(mktemp -d)
  git clone -q --no-checkout "$repo" "$tmp/work" || return 1
  git -C "$tmp/work" show-ref -q --verify "refs/heads/$branch" \
    || git -C "$tmp/work" branch -q "$branch" "origin/$branch" || return 1
  # The ID hashes the first identity, so a fork's would equal its parent's: the first
  # description is the gitea address and id, the real one follows right after.
  r rad init "$tmp/work" --name "$name" --description "$ORIGIN/$owner/$lower #$id" \
    --default-branch "$branch" --public --no-confirm >/dev/null || return 1
  (cd "$tmp/work" && r rad .) > "$dir/rid.new" || return 1
  echo "$who" > "$dir/node"
  mv "$dir/rid.new" "$dir/rid"
  rm -rf "$tmp"
  echo "$owner/$lower: published as $(cat "$dir/rid") by $who's node"
}

# A repository published before nodes were per user is taken on by the node whose key
# is already its delegate; one never moves to another node's storage.
adopt() {
  local had
  had=$(cat "$dir/node" 2>/dev/null || true)
  if [ -z "$had" ]; then
    r rad inspect "$rid" --delegates 2>/dev/null | grep -q "^did:key:$nid" \
      || { echo "$owner/$lower: $who's node is not its delegate" >&2; return 1; }
    echo "$who" > "$dir/node"
    rm -f "$dir/signer" "$dir/meta"
    echo "$owner/$lower: signed by $who's node"
  elif [ "$had" != "$who" ]; then
    echo "$owner/$lower: published by $had's node, now $who's: not moved" >&2
    return 1
  fi
}

# Mirrors branches and tags, deletions included, straight from gitea's repository;
# the bridge's patch branches stay on their own side.
fingerprint() {
  local ns=refs/namespaces/$nid/refs
  # The node's copy counts too, so anything that diverged from gitea is put back.
  { git -C "$repo" for-each-ref --format='%(objectname) %(refname)' \
      --exclude=refs/heads/rad/patch --exclude=refs/heads/patches refs/heads refs/tags
    git -C "$storage" for-each-ref --format='%(objectname) %(refname)' \
      --exclude="$ns/heads/patches" "$ns/heads" "$ns/tags"; } | sha256sum
}

mirror() {
  local ns=refs/namespaces/$nid/refs stale="" prune=--prune current mine canonical
  # The node's rad/id is the identity it vouches for, which seeds read to follow a
  # change of delegates: it catches up with the canonical one when behind, and is
  # left alone when ahead, holding the node's own proposal.
  mine=$(git -C "$storage" rev-parse -q --verify "$ns/rad/id" || true)
  canonical=$(git -C "$storage" rev-parse refs/rad/id)
  if [ "$mine" != "$canonical" ] && { [ -z "$mine" ] || git -C "$storage" merge-base --is-ancestor "$mine" "$canonical"; }; then
    stale=1
  fi
  [ -n "$stale" ] || [ "$(fingerprint)" != "$(cat "$dir/refs" 2>/dev/null)" ] || return 0
  # Radicle refuses to delete its default branch: while gitea's is another one, this
  # pass only adds and updates, describe() moves the default, the next pass prunes.
  current=$(printf '%s' "$payload" | jq -r '."xyz.radicle.project".defaultBranch // empty')
  if [ -n "$current" ] && ! git -C "$repo" show-ref -q --verify "refs/heads/$current"; then prune=""; fi
  # shellcheck disable=SC2086
  r git -C "$repo" push -q $prune "rad://${rid#rad:}/$nid" '+refs/heads/*:refs/heads/*' \
    '^refs/heads/rad/patch/*' '^refs/heads/patches/*' '+refs/tags/*:refs/tags/*' || return 1
  if [ -n "$stale" ]; then
    git -C "$storage" update-ref "$ns/rad/id" refs/rad/id
    # A push through git-remote-rad signs the namespace again, rad/id included.
    r git -C "$repo" push -q "rad://${rid#rad:}/$nid" "$(git -C "$repo" rev-parse HEAD):refs/heads/radicle-sign" 2>/dev/null || true
    r git -C "$repo" push -q "rad://${rid#rad:}/$nid" ":refs/heads/radicle-sign" 2>/dev/null || true
    echo "$owner/$lower: rad/id signed"
  fi
  fingerprint > "$dir/refs"
  changed=1
  echo "$owner/$lower: pushed"
}

# Name, description, default branch and gitea's other settings as the identity holds them.
held() {
  printf '%s' "$payload" | jq -cS '{name: ."xyz.radicle.project".name,
    description: ."xyz.radicle.project".description, defaultBranch: ."xyz.radicle.project".defaultBranch,
    gitea: ((."com.bresilla.gitea" // {}) | {url, website, topics, mirror})}'
}

# The identity follows gitea's settings, compared with what it really holds: one
# revision per change. A revision needs a majority of the delegates, so with recovery
# keys it waits for one of their votes; it is proposed once and the pass fails until
# it is in effect.
describe() {
  local want rev extra=() key
  want=$(jq -cS -n --arg n "$name" --arg d "$description" --arg b "$branch" --argjson g "$settings_doc" \
    '{name: $n, description: $d, defaultBranch: $b, gitea: $g}')
  if [ "$want" = "$(held)" ]; then
    if [ -e "$dir/pending" ]; then rm -f "$dir/pending" "$dir/refs"; fi
    return 0
  fi
  if [ "$(sed 1d "$dir/pending" 2>/dev/null)" = "$want" ]; then
    waiting "$(head -1 "$dir/pending")"
    return 0
  fi
  for key in url website topics mirror; do
    extra+=(--payload com.bresilla.gitea "$key" "$(printf '%s' "$settings_doc" | jq -c ".$key")")
  done
  local args=(--repo "$rid" --title "Follow gitea" --no-confirm -q
    --payload xyz.radicle.project name "$(jq -n --arg v "$name" '$v')"
    --payload xyz.radicle.project description "$(jq -n --arg v "$description" '$v')"
    --payload xyz.radicle.project defaultBranch "$(jq -n --arg v "$branch" '$v')"
    "${extra[@]}")
  local old
  # rad says its errors on stdout.
  if ! rev=$(r rad id update "${args[@]}" 2>&1); then
    # The node's own older proposal blocks a new one: it is redacted, then proposed again.
    old=$(grep -o "sibling revision '[0-9a-f]\{40\}'" <<< "$rev" | grep -o '[0-9a-f]\{40\}' || true)
    if [ -z "$old" ] || ! r rad id redact "$old" --repo "$rid" --no-confirm -q \
        || ! rev=$(r rad id update "${args[@]}" 2>&1); then
      echo "$owner/$lower: $rev" >&2
      return 1
    fi
    echo "$owner/$lower: older proposal $old redacted"
  fi
  changed=1
  payload=$(r rad inspect "$rid" --payload)
  if [ "$want" != "$(held)" ]; then
    printf '%s\n%s\n' "$rev" "$want" > "$dir/pending"
    waiting "$rev"
    return 0
  fi
  # A new default lets the next mirror prune the old one.
  rm -f "$dir/refs"
  echo "$owner/$lower: identity updated"
}

waiting() {
  echo "$owner/$lower: identity revision $1 waits for a delegate's vote: rad id accept $1 --repo $rid" >&2
  failed=1
}

# Copies already on the network stay there; the node only stops serving them.
withdraw() {
  [ -s "$dir/rid" ] && [ ! -e "$dir/withdrawn" ] || return 0
  local had
  had=$(cat "$dir/node" 2>/dev/null || echo "${order[0]}")
  if [ -n "${home_of[$had]:-}" ]; then
    who=$had r rad unseed "$(cat "$dir/rid")" >/dev/null || return 1
  else
    echo "$owner/$lower: $had has no node any more" >&2
  fi
  touch "$dir/withdrawn"
  echo "$owner/$lower: withdrawn"
}

# The node's recovery keys join its repositories, threshold 1.
recover() {
  local did
  for did in ${recovery_of[$who]}; do
    r rad inspect "$rid" --delegates 2>/dev/null | awk '{ print $1 }' | grep -qx "$did" && continue
    r rad id update --repo "$rid" --title "Recovery key" --no-confirm -q \
      --delegate "$did" --threshold 1 >/dev/null || return 1
    r rad inspect "$rid" --delegates | awk '{ print $1 }' | grep -qx "$did" \
      || { echo "$owner/$lower: recovery key $did not in effect" >&2; return 1; }
    changed=1
    echo "$owner/$lower: recovery key $did added"
  done
}

sync_one() {
  dir="$repos/$id" changed=""
  repo="$REPOSITORIES/$owner/$lower.git"
  mkdir -p "$dir"
  node_of "$owner"
  [ "$public" = 1 ] && [ -n "$who" ] || { withdraw; return; }
  nid=${nid_of[$who]}
  [ -s "$dir/rid" ] || publish || return 1
  rid=$(cat "$dir/rid")
  storage=${home_of[$who]}/storage/${rid#rad:}
  adopt || return 1
  if [ -e "$dir/withdrawn" ]; then
    r rad seed "$rid" --scope "$scope" >/dev/null || return 1
    rm "$dir/withdrawn"
    echo "$scope" > "$dir/scope"
    echo "$owner/$lower: seeded again"
  fi
  # Whose changes the node fetches: anyone's, or only from nodes it follows.
  if [ "$scope" != "$(cat "$dir/scope" 2>/dev/null || echo all)" ]; then
    r rad seed "$rid" --scope "$scope" >/dev/null || return 1
    echo "$scope" > "$dir/scope"
    echo "$owner/$lower: fetches from $scope"
  fi
  payload=$(r rad inspect "$rid" --payload) || return 1
  mirror || return 1
  describe || return 1
  recover || return 1
  # Seeds fetch a namespace when its own node announces it.
  [ -z "$changed" ] || r timeout 60 rad sync --announce "$rid" >/dev/null 2>&1 || true
  mkdir -p "$out/$owner"
  # Open patches and issues with their gitea twins, as the bridge last saw them.
  network=$(jq -c . "$SYNC_STATE/bridge/$id.network.json" 2>/dev/null || echo null)
  status | jq -n --arg rid "$rid" --arg node "$nid" --arg alias "$who" \
    --argjson delegates "$(delegates)" --arg updated "$(date -u +%FT%TZ)" --argjson network "${network:-null}" \
    '{rid: $rid, node: $node, alias: $alias, delegates: $delegates, seeds: [inputs], updated: $updated,
      network: $network}' > "$out/$owner/$lower.json"
}

# Every other node holding the repository, from the node's own table of who has which refs.
status() {
  r rad sync status "$rid" 2>/dev/null | awk -F '  +' '/^│ /{ sub(/^│ +/, ""); sub(/ +│$/, ""); print }' \
    | tail -n +2 | grep -v '^(you)' | jq -R -c 'split("  +"; null) | {
        node: .[0], alias: (.[1] // ""),
        status: ({"✓": "synced", "✗": "behind", "!": "unannounced"}[.[2] // ""] // "unknown"),
        when: (.[4] // "")}' | hidden || true
}

# Leaves out nodes listed in HIDE_NODES (retired or throwaway ones). rad shortens
# each ID to its start and end, cut to fit its table: matched on both parts.
hidden() {
  jq -c --arg hide "${HIDE_NODES:-}" '
    ($hide | split(" ") | map(select(. != "") | sub("^did:key:"; "") | ascii_downcase)) as $ids
    | select(.node as $n | ($n | ascii_downcase | split("…")) as [$a, $b]
        | [$ids[] | select(startswith($a) and (.[-8:] | contains($b // "")))] | length == 0)'
}

# The keys that sign the repository's identity, with their aliases.
delegates() {
  r rad inspect "$rid" --delegates 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(. != "") | capture("^(?<did>\\S+)( \\((?<alias>.*)\\))?$"))' || echo '[]'
}

field() { printf '%s' "$row" | jq -r "$1"; }

failed=0
while IFS= read -r row; do
  id=$(field .id) owner=$(field .owner) lower=$(field .lower) name=$(field .name)
  description=$(field '.description[0:255]') branch=$(field .branch)
  settings_doc=$(printf '%s' "$row" | jq -c --arg url "$ORIGIN/$owner/$lower" \
    '{url: $url, website: .website, topics: (.topics | fromjson? // []), mirror: (.mirror == 1)}')
  public=$(printf '%s' "$row" | jq -r --arg t "$OPT_OUT" \
    'if ((.topics | fromjson? // []) | index($t)) then 0 else .public end')
  # The repository's own settings page, saved by the settings service.
  settings=$(cat "$SYNC_STATE/settings/$id.json" 2>/dev/null || echo '{}')
  [ "$(printf '%s' "$settings" | jq -r '.publish // true')" = true ] || public=0
  scope=$(printf '%s' "$settings" | jq -r 'if .scope == "followed" then "followed" else "all" end')
  sync_one || { echo "$owner/$lower: sync failed" >&2; failed=1; }
done < <(printf '%s' "$listing" | jq -c '.[]')

# Repositories gone from gitea.
for dir in "$repos"/*; do
  [ -d "$dir" ] || continue
  id=$(basename "$dir")
  printf '%s' "$listing" | jq -e --argjson id "$id" 'any(.[]; .id == $id)' >/dev/null && continue
  owner=deleted lower=$id
  withdraw || { echo "repository $id: withdraw failed" >&2; failed=1; }
done

rm -rf "$SYNC_STATE/public.old"
[ ! -e "$SYNC_STATE/public" ] || mv "$SYNC_STATE/public" "$SYNC_STATE/public.old"
mv "$out" "$SYNC_STATE/public"
rm -rf "$SYNC_STATE/public.old"

# Patches and issues, once everything is published.
if [ -n "${BRIDGE:-}" ]; then
  NODES_FILE=$RUNTIME_DIRECTORY/nodes.json python3 "$BRIDGE" || failed=1
fi
exit "$failed"
