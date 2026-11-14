set -euo pipefail

# A Radicle home of its own: the node's storage and sockets, the key from the credential.
home=$RUNTIME_DIRECTORY/home
mkdir -p "$home/keys" "$RAD_STATE"/{storage,node,cobs}
for d in storage node cobs; do ln -sfn "$RAD_STATE/$d" "$home/$d"; done
ln -sfn "$RAD_CONFIG" "$home/config.json"
install -m 0600 "$CREDENTIALS_DIRECTORY/key" "$home/keys/radicle"
ssh-keygen -y -f "$home/keys/radicle" > "$home/keys/radicle.pub"
export RAD_HOME=$home HOME=$home
nid=$(rad node status --only nid)

# Gitea owns the repositories; git-remote-rad's libgit2 reads only the config file, not -c.
printf '[safe]\n\tdirectory = *\n' > "$home/.gitconfig"

# A home per held user key, over the same storage; prints the key's Node ID.
make_home() {
  mkdir -p "$1/keys"
  for d in storage node cobs; do ln -sfn "$RAD_STATE/$d" "$1/$d"; done
  jq --arg a "$3" '.node.alias = $a' "$RAD_CONFIG" > "$1/config.json"
  install -m 0600 "$2" "$1/keys/radicle"
  ssh-keygen -y -f "$2" > "$1/keys/radicle.pub"
  cp "$home/.gitconfig" "$1/.gitconfig"
  RAD_HOME=$1 rad self --did | sed 's/^did:key://'
}

# Keys gitea holds for its users, one directory per user id: the current key and
# retired ones, kept so repositories they signed can be handed over.
declare -A signs_for
keys='{}'
for kd in "$KEYS"/*/; do
  uid=$(basename "$kd")
  [[ "$uid" =~ ^[0-9]+$ ]] || continue
  user=$(sqlite3 -cmd '.timeout 5000' "file:$DATABASE?mode=ro" "select lower_name || ' ' || name from user where id = $uid and type = 0")
  [ -n "$user" ] || continue
  for key in "$kd"radicle "$kd"retired/*; do
    [ -s "$key" ] || continue
    h=$RUNTIME_DIRECTORY/users/$uid-$(basename "$key")
    k=$(make_home "$h" "$key" "${user#* }")
    keys=$(printf '%s' "$keys" | jq --arg k "$k" --arg u "${user% *}" --arg n "${user#* }" --arg h "$h" \
      --argjson c "$([ "$key" = "${kd}radicle" ] && echo true || echo false)" \
      '.[$k] = {user: $u, name: $n, home: $h, current: $c}')
  done
done
# Users listed in the configuration sign their own repositories; their key is made once.
for user in $KEY_USERS; do
  uid=$(sqlite3 -cmd '.timeout 5000' "file:$DATABASE?mode=ro" "select id from user where lower_name = lower('$user') and type = 0")
  [ -n "$uid" ] || continue
  kd=$KEYS/$uid
  if [ ! -s "$kd/radicle" ]; then
    mkdir -p "$kd"
    rm -f "$kd/radicle.new" "$kd/radicle.new.pub"
    ssh-keygen -q -t ed25519 -N "" -C "" -f "$kd/radicle.new"
    mv "$kd/radicle.new" "$kd/radicle"
    rm -f "$kd/radicle.new.pub"
    h=$RUNTIME_DIRECTORY/users/$uid-radicle
    k=$(make_home "$h" "$kd/radicle" "$user")
    keys=$(printf '%s' "$keys" | jq --arg k "$k" --arg u "${user,,}" --arg n "$user" --arg h "$h" \
      '.[$k] = {user: $u, name: $n, home: $h, current: true}')
    echo "$user: Radicle key made, did:key:$k"
  fi
  signs_for[${user,,}]=$(printf '%s' "$keys" | jq -r --arg u "${user,,}" 'to_entries[] | select(.value.user == $u and .value.current) | .key')
done
# Organisations' repositories are signed by one user's key, when configured.
if [ -n "${ORG_KEY:-}" ] && [ -n "${signs_for[${ORG_KEY,,}]:-}" ]; then
  for org in $(sqlite3 -cmd '.timeout 5000' "file:$DATABASE?mode=ro" "select lower_name from user where type = 1"); do
    signs_for[$org]=${signs_for[${ORG_KEY,,}]}
  done
fi
printf '%s' "$keys" > "$RUNTIME_DIRECTORY/keys.json"
home_of() { if [ "$1" = "$nid" ]; then echo "$home"; else jq -r --arg k "$1" '.[$k].home // empty' "$RUNTIME_DIRECTORY/keys.json"; fi; }
as() { local h; h=$(home_of "$1"); shift; [ -n "$h" ] && RAD_HOME=$h HOME=$h "$@"; }

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
  as "$want" rad init "$tmp/work" --name "$name" --description "$ORIGIN/$owner/$lower #$id" \
    --default-branch "$branch" --public --no-confirm >/dev/null || return 1
  (cd "$tmp/work" && rad .) > "$dir/rid.new" || return 1
  echo "$want" > "$dir/signer"
  mv "$dir/rid.new" "$dir/rid"
  rm -f "$dir/meta"
  rm -rf "$tmp"
  echo "$owner/$lower: published as $(cat "$dir/rid")"
}

# Mirrors branches and tags, deletions included, straight from gitea's repository;
# the bridge's patch branches stay on their own side.
fingerprint() {
  local ns=refs/namespaces/$signer/refs
  # The signer's copy counts too, so a push that diverged from gitea is put back.
  { git -C "$repo" for-each-ref --format='%(objectname) %(refname)' \
      --exclude=refs/heads/rad/patch --exclude=refs/heads/patches refs/heads refs/tags
    git -C "$RAD_STATE/storage/${rid#rad:}" for-each-ref --format='%(objectname) %(refname)' \
      --exclude="$ns/heads/patches" "$ns/heads" "$ns/tags"; } | sha256sum
}

mirror() {
  local storage=$RAD_STATE/storage/${rid#rad:} ns=refs/namespaces/$signer/refs
  # The signer's rad/id is the identity it vouches for: seeds read the delegates' to
  # follow a change of delegates, so it tracks the canonical one.
  local stale=""
  [ "$(git -C "$storage" rev-parse -q --verify "$ns/rad/id")" = "$(git -C "$storage" rev-parse refs/rad/id)" ] || stale=1
  [ -n "$stale" ] || [ "$(fingerprint)" != "$(cat "$dir/refs" 2>/dev/null)" ] || return 0
  # Radicle refuses to delete its default branch: while gitea's is another one, this
  # pass only adds and updates, describe() moves the default, the next pass prunes.
  local prune=--prune current
  current=$(rad inspect "$rid" --payload 2>/dev/null | jq -r '."xyz.radicle.project".defaultBranch // empty')
  if [ -n "$current" ] && ! git -C "$repo" show-ref -q --verify "refs/heads/$current"; then prune=""; fi
  # shellcheck disable=SC2086
  as "$signer" git -C "$repo" push -q $prune "rad://${rid#rad:}/$signer" '+refs/heads/*:refs/heads/*' \
    '^refs/heads/rad/patch/*' '^refs/heads/patches/*' '+refs/tags/*:refs/tags/*' || return 1
  if [ -n "$stale" ]; then
    git -C "$storage" update-ref "$ns/rad/id" refs/rad/id
    # A push through git-remote-rad signs the namespace again, rad/id included.
    as "$signer" git -C "$repo" push -q "rad://${rid#rad:}/$signer" "$(git -C "$repo" rev-parse HEAD):refs/heads/radicle-sign" 2>/dev/null || true
    as "$signer" git -C "$repo" push -q "rad://${rid#rad:}/$signer" ":refs/heads/radicle-sign" 2>/dev/null || true
    echo "$owner/$lower: rad/id signed"
  fi
  fingerprint > "$dir/refs"
  changed=1
  echo "$owner/$lower: pushed"
}

# Name, description, default branch and the rest of gitea's settings follow gitea's,
# in one identity revision per change.
describe() {
  local meta extra key
  meta=$(printf '%s\n%s\n%s\n%s' "$name" "$description" "$branch" "$settings_doc")
  [ "$meta" != "$(cat "$dir/meta" 2>/dev/null)" ] || return 0
  extra=()
  for key in url website topics mirror; do
    extra+=(--payload com.bresilla.gitea "$key" "$(printf '%s' "$settings_doc" | jq -c ".$key")")
  done
  as "$signer" rad id update --repo "$rid" --title "Follow gitea" --no-confirm -q \
    --payload xyz.radicle.project name "$(jq -n --arg v "$name" '$v')" \
    --payload xyz.radicle.project description "$(jq -n --arg v "$description" '$v')" \
    --payload xyz.radicle.project defaultBranch "$(jq -n --arg v "$branch" '$v')" \
    "${extra[@]}" >/dev/null || return 1
  printf '%s\n' "$meta" > "$dir/meta"
  changed=1
  echo "$owner/$lower: identity updated"
}

# Copies already on the network stay there; this node only stops serving them.
withdraw() {
  [ -s "$dir/rid" ] && [ ! -e "$dir/withdrawn" ] || return 0
  rad unseed "$(cat "$dir/rid")" >/dev/null || return 1
  touch "$dir/withdrawn"
  echo "$owner/$lower: withdrawn"
}

# The owner's key takes over as the only delegate, or hive's again: the old signer adds
# the new one, the code moves to the new one's copy, then the new one drops the old.
handover() {
  local dels old rev
  [ "$signer" != "$want" ] || return 0
  [ -n "$(home_of "$signer")" ] || { echo "$owner/$lower: no key for signer $signer" >&2; return 1; }
  dels=$(rad inspect "$rid" --delegates 2>/dev/null | awk '{ print $1 }')
  if ! grep -qx "did:key:$want" <<< "$dels"; then
    as "$signer" rad id update --repo "$rid" --title "Signed by $owner" --no-confirm -q \
      --delegate "did:key:$want" --threshold 1 >/dev/null || return 1
  fi
  old=$signer signer=$want
  rm -f "$dir/refs"
  mirror || return 1
  # Dropping a delegate needs that delegate's vote as well.
  if rad inspect "$rid" --delegates | grep -q "^did:key:$old"; then
    rev=$(as "$want" rad id update --repo "$rid" --title "Signed by $owner" --no-confirm -q \
      --rescind "did:key:$old") || return 1
    as "$old" rad id accept "$rev" --repo "$rid" --no-confirm -q >/dev/null || return 1
  fi
  ! rad inspect "$rid" --delegates | grep -q "^did:key:$old" || return 1
  echo "$want" > "$dir/signer"
  echo "$owner/$lower: delegate is now did:key:$want"
}

# The offline recovery keys join every repository a held key signs, threshold 1. The
# signer's rad/id follows on the next pass, which announces it again.
recover() {
  local did dels
  [ "$signer" != "$nid" ] && [ -n "${RECOVERY:-}" ] || return 0
  dels=$(rad inspect "$rid" --delegates 2>/dev/null | awk '{ print $1 }')
  for did in $RECOVERY; do
    grep -qx "$did" <<< "$dels" && continue
    as "$signer" rad id update --repo "$rid" --title "Recovery key" --no-confirm -q \
      --delegate "$did" --threshold 1 >/dev/null || return 1
    changed=1
    echo "$owner/$lower: recovery key $did added"
  done
}

# Seeds fetch a namespace when its own key announces it: the signer's and the node's.
announce() {
  as "$signer" timeout 60 rad sync --announce "$rid" >/dev/null 2>&1 || true
  [ "$signer" = "$nid" ] || timeout 60 rad sync --announce "$rid" >/dev/null 2>&1 || true
}

sync_one() {
  dir="$repos/$id" changed=""
  repo="$REPOSITORIES/$owner/$lower.git"
  mkdir -p "$dir"
  [ "$public" = 1 ] || { withdraw; return; }
  want=${signs_for[$owner]:-$nid}
  [ -s "$dir/rid" ] || publish || return 1
  rid=$(cat "$dir/rid")
  signer=$(cat "$dir/signer" 2>/dev/null || echo "$nid")
  handover || return 1
  if [ -e "$dir/withdrawn" ]; then
    rad seed "$rid" --scope "$scope" >/dev/null || return 1
    rm "$dir/withdrawn"
    echo "$scope" > "$dir/scope"
    echo "$owner/$lower: seeded again"
  fi
  # Whose changes the node fetches: anyone's, or only from nodes it follows.
  if [ "$scope" != "$(cat "$dir/scope" 2>/dev/null || echo all)" ]; then
    rad seed "$rid" --scope "$scope" >/dev/null || return 1
    echo "$scope" > "$dir/scope"
    echo "$owner/$lower: fetches from $scope"
  fi
  mirror || return 1
  describe || return 1
  recover || return 1
  [ -z "$changed" ] || announce
  mkdir -p "$out/$owner"
  # Open patches and issues with their gitea twins, as the bridge last saw them.
  network=$(jq -c . "$SYNC_STATE/bridge/$id.network.json" 2>/dev/null || echo null)
  status | jq -n --arg rid "$rid" --arg node "$nid" --arg alias "$RADICLE" \
    --argjson delegates "$(delegates)" --arg updated "$(date -u +%FT%TZ)" --argjson network "${network:-null}" \
    '{rid: $rid, node: $node, alias: $alias, delegates: $delegates, seeds: [inputs], updated: $updated,
      network: $network}' > "$out/$owner/$lower.json"
}

# Every other node holding the repository, from the node's own table of who has which refs.
status() {
  rad sync status "$rid" 2>/dev/null | awk -F '  +' '/^│ /{ sub(/^│ +/, ""); sub(/ +│$/, ""); print }' \
    | tail -n +2 | grep -v '^(you)' | jq -R -c 'split("  +"; null) | {
        node: .[0], alias: (.[1] // ""),
        status: ({"✓": "synced", "✗": "behind", "!": "unannounced"}[.[2] // ""] // "unknown"),
        when: (.[4] // "")}' || true
}

# The keys that sign the repository's identity, with their aliases.
delegates() {
  rad inspect "$rid" --delegates 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(. != "") | capture("^(?<did>\\S+)( \\((?<alias>.*)\\))?$"))' || echo '[]'
}

field() { printf '%s' "$row" | jq -r "$1"; }

failed=0
# Fast-forwards over Radicle land in gitea first, so the mirror below does not undo them.
if [ -n "${BRIDGE:-}" ]; then
  KEYS_FILE=$RUNTIME_DIRECTORY/keys.json python3 "$BRIDGE" "$nid" pushes || failed=1
fi

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

# Patches, issues and allowed pushes, once everything is published.
if [ -n "${BRIDGE:-}" ]; then
  KEYS_FILE=$RUNTIME_DIRECTORY/keys.json python3 "$BRIDGE" "$nid" || failed=1
fi
exit "$failed"
