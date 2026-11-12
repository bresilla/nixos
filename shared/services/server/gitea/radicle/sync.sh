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

repos="$SYNC_STATE/repos"
out="$SYNC_STATE/public.new"
rm -rf "$out"
mkdir -p "$repos" "$out"
echo '{}' > "$out/none.json"

# Owner visibility 0 is public; a private or limited owner hides its repositories.
query="select r.id, lower(r.owner_name) as owner, r.lower_name as lower, r.name,
  coalesce(r.description, '') as description, coalesce(r.default_branch, '') as branch,
  coalesce(r.topics, '[]') as topics,
  (r.is_private = 0 and r.is_mirror = 0 and r.is_empty = 0 and u.visibility = 0) as public
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
  rad init "$tmp/work" --name "$name" --description "$description" \
    --default-branch "$branch" --public --no-confirm >/dev/null || return 1
  (cd "$tmp/work" && rad .) > "$dir/rid.new" || return 1
  mv "$dir/rid.new" "$dir/rid"
  printf '%s\n%s\n%s\n' "$name" "$description" "$branch" > "$dir/meta"
  rm -rf "$tmp"
  echo "$owner/$lower: published as $(cat "$dir/rid")"
}

# Mirrors branches and tags, deletions included, straight from gitea's repository.
mirror() {
  local refs
  refs=$(git -C "$repo" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sha256sum) || return 1
  [ "$refs" != "$(cat "$dir/refs" 2>/dev/null)" ] || return 0
  git -C "$repo" push -q --prune "rad://${rid#rad:}/$nid" \
    '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' || return 1
  echo "$refs" > "$dir/refs"
  echo "$owner/$lower: pushed"
}

# Name, description and default branch follow gitea's.
describe() {
  local meta
  meta=$(printf '%s\n%s\n%s' "$name" "$description" "$branch")
  [ "$meta" != "$(cat "$dir/meta" 2>/dev/null)" ] || return 0
  rad id update --repo "$rid" --title "Follow gitea" --no-confirm -q \
    --payload xyz.radicle.project name "$(jq -n --arg v "$name" '$v')" \
    --payload xyz.radicle.project description "$(jq -n --arg v "$description" '$v')" \
    --payload xyz.radicle.project defaultBranch "$(jq -n --arg v "$branch" '$v')" >/dev/null || return 1
  printf '%s\n' "$meta" > "$dir/meta"
  echo "$owner/$lower: identity updated"
}

# Copies already on the network stay there; this node only stops serving them.
withdraw() {
  [ -s "$dir/rid" ] && [ ! -e "$dir/withdrawn" ] || return 0
  rad unseed "$(cat "$dir/rid")" >/dev/null || return 1
  touch "$dir/withdrawn"
  echo "$owner/$lower: withdrawn"
}

sync_one() {
  dir="$repos/$id"
  repo="$REPOSITORIES/$owner/$lower.git"
  mkdir -p "$dir"
  [ "$public" = 1 ] || { withdraw; return; }
  [ -s "$dir/rid" ] || publish || return 1
  rid=$(cat "$dir/rid")
  if [ -e "$dir/withdrawn" ]; then
    rad seed "$rid" --scope all >/dev/null || return 1
    rm "$dir/withdrawn"
    echo "$owner/$lower: seeded again"
  fi
  mirror || return 1
  describe || return 1
  mkdir -p "$out/$owner"
  jq -n --arg rid "$rid" --arg node "$nid" '{rid: $rid, node: $node}' > "$out/$owner/$lower.json"
}

field() { printf '%s' "$row" | jq -r "$1"; }

failed=0
while IFS= read -r row; do
  id=$(field .id) owner=$(field .owner) lower=$(field .lower) name=$(field .name)
  description=$(field '.description[0:255]') branch=$(field .branch)
  public=$(printf '%s' "$row" | jq -r --arg t "$OPT_OUT" \
    'if ((.topics | fromjson? // []) | index($t)) then 0 else .public end')
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
exit "$failed"
