#!/bin/bash
# H1 experiment: is the wedge caused by a blocking cross-module sync call in a slot?
set -u
REPO=<repo>
OUT="$1"; MODE="${2:-all}"; mkdir -p "$OUT"
PORT=3789; export QML_INSPECTOR_PORT=$PORT QML_INSPECTOR_HOST=localhost
DB="$OUT/forum.db"
lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && { echo "port busy"; exit 1; }
LOGOS_NO_SCHEME_REGISTER=1 FORUM_DB_PATH="$DB" "$REPO/result-ui-dev/bin/run-logos-standalone-ui" -platform offscreen >"$OUT/host.log" 2>&1 &
APP=$!
for i in $(seq 1 30); do lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 2; done
node drive.mjs "$MODE" > "$OUT/drive.jsonl" 2>"$OUT/drive.err"; echo "drive rc=$?"
kill $APP 2>/dev/null; sleep 2; kill -9 $APP 2>/dev/null
pkill -9 -f "logos-forum_module-plugin-dir" 2>/dev/null; sleep 1
echo "port listeners: $(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | wc -l)"
echo "leftover: $(pgrep -f 'run-logos-standalone-ui|logos-forum_module-plugin-dir' | wc -l)"
sqlite3 "$DB" "select alias from accounts;" 2>&1 | head
cat "$OUT/drive.jsonl"
