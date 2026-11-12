# Restarts every failed job of a repository's latest run on build.bresilla.com.
# Usage: sudo ci-restart <owner>/<name>
set -euo pipefail

repo=${1:?usage: sudo ci-restart <owner>/<name>}
[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "not a repository: $repo" >&2; exit 2; }

# Inside the ci container, against murosd itself; reads need no token.
inside() { nixos-container run ci -- "$@"; }
get() { inside curl -fsS -H "Host: build.bresilla.com" "http://127.0.0.1:8090/api/v1/$1"; }

run=$(get "repos/$repo/runs" | jq -r '.[0].id // empty')
[[ -n $run ]] || { echo "$repo has no runs" >&2; exit 1; }
mapfile -t jobs < <(get "runs/$run/jobs" | jq -r '.[] | select(.status == "failed") | .id')
if (( ${#jobs[@]} == 0 )); then
  echo "nothing failed in the latest run of $repo ($run)"
  exit 0
fi
echo "restarting ${#jobs[@]} failed job(s) of $repo, run $run"

# A ten-minute token that may only control this repository, made by murosd's own admin tool.
start=$(inside systemctl show -P ExecStart murosd)
murosd=$(grep -o '/nix/store/[^ ;]*/bin/murosd' <<< "$start" | head -1)
murosadm=${murosd%/murosd}/murosadm
config=$(grep -oE -- '-f /nix/store/[^ ;]*\.toml' <<< "$start" | head -1 | cut -d' ' -f2)
token=$(inside "$murosadm" -f "$config" make-token --sub ci-restart --validity 10m --control "$repo" | tail -1)

# Muros refuses a restart while the run re-evaluates after the previous one; wait it out.
for job in "${jobs[@]}"; do
  for _ in $(seq 1 60); do
    code=$(inside curl -s -o /dev/null -w '%{http_code}' -X POST -H "Host: build.bresilla.com" \
      -H "Authorization: Bearer $token" "http://127.0.0.1:8090/api/v1/jobs/$job/restart")
    [[ $code == 409 ]] || break
    sleep 5
  done
  attr=$(get "runs/$run/jobs" | jq -r --arg j "$job" '.[] | select(.id == $j) | .attr')
  if [[ $code == 200 ]]; then echo "  restarted $attr"; else echo "  $attr: murosd answered $code" >&2; fi
done
echo "follow it at https://build.bresilla.com"
