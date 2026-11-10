#!/usr/bin/env bash
set -euo pipefail
binary=$1
custom=$2
directory=$(mktemp -d "${3}/gitea-fixture.XXXXXX")
chmod 700 "$directory"
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi' EXIT
cat > "$directory/app.ini" <<EOF
APP_NAME = Shared UI fixture
RUN_USER = $(id -un)
RUN_MODE = prod
[server]
PROTOCOL = http
HTTP_ADDR = 127.0.0.1
HTTP_PORT = 18027
ROOT_URL = http://127.0.0.1:18027/
DISABLE_SSH = true
APP_DATA_PATH = $directory/data
[database]
DB_TYPE = sqlite3
PATH = $directory/gitea.db
[repository]
ROOT = $directory/repos
[security]
INSTALL_LOCK = true
[service]
DISABLE_REGISTRATION = true
[log]
MODE = console
LEVEL = Warn
EOF
"$binary" --work-path "$directory" --custom-path "$custom" --config "$directory/app.ini" web --pid "$directory/pid" > "$directory/server.log" 2>&1 &
pid=$!
for attempt in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:18027/api/healthz > "$directory/health.json" 2>/dev/null; then break; fi
  kill -0 "$pid"
  sleep 1
done
for route in explore/repos user/login; do
  file=${route//\//-}
  curl -fsS -D "$directory/$file.headers" "http://127.0.0.1:18027/$route" -o "$directory/$file.html"
  grep -q 'BresillaUI.accent()' "$directory/$file.html"
  grep -q '<script nonce=' "$directory/$file.html"
  ! grep -q '@SITE_' "$directory/$file.html"
done
curl -fsS http://127.0.0.1:18027/assets/img/logo.svg -o "$directory/logo.svg"
cmp "$directory/logo.svg" "$custom/public/assets/img/logo.svg"
printf '%s\n' "$directory" > "$3/gitea-fixture-latest"
echo "GITEA_NATIVE_TEMPLATE_OK $directory"
