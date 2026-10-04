#!/usr/bin/env bash
# LP-0026 Forum — live offline-reader test (logos.dev, Mix Required).
# A joins via the in-app Connect action, posts one TECHNICAL TEST DATA post,
# and QUITS. Only then does B start, with an empty store; B joins and must
# obtain A's post from the network (store backfill), with A offline.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${FORUM_STATE:-$HOME/.local/share/lp0026-forum-dev/m6-history}"
EVID="$REPO_ROOT/evidence/m6-live/history-$(date +%Y%m%d-%H%M%S)"
UI_DEV="$REPO_ROOT/result-ui-dev/bin/run-logos-standalone-ui"
GAP="${FORUM_HISTORY_GAP:-30}"
mkdir -p "$STATE" "$EVID"
[ -x "$UI_DEV" ] || { echo "FAIL: build the launcher first: nix build .#ui-dev"; exit 1; }
lsof -nP -iTCP:3768 -sTCP:LISTEN >/dev/null 2>&1 && { echo "FAIL: port 3768 busy"; exit 1; }
PID=""
stop_app() {
  [ -n "$PID" ] || return 0
  kill "$PID" 2>/dev/null; sleep 3
  ps -p "$PID" >/dev/null 2>&1 && { echo "SIGKILL $PID"; kill -9 "$PID" 2>/dev/null; }
  PID=""
}
cleanup() {
  stop_app
  pgrep -fl 'run-logos-standalone-ui' && echo "WARNING: leftover app processes" \
    || echo "cleanup verified: no live-run processes remain"
}
trap cleanup EXIT
rm -f "$STATE"/a-forum.db* "$STATE"/b-forum.db*
unset FORUM_TRANSPORT_CONFIG
TEXT="TECHNICAL TEST DATA: offline-reader history check $(date -u +%FT%TZ)"

LOGOS_QML_HOT_RELOAD=0 FORUM_DB_PATH="$STATE/a-forum.db" QML_INSPECTOR_PORT=3768 \
  "$UI_DEV" >"$EVID/a-app.log" 2>&1 &
PID=$!; sleep 8
node "$REPO_ROOT/tools/m6_history_driver.mjs" --port 3768 --phase post --text "$TEXT" \
  | tee "$EVID/a-driver.json"
ARC=${PIPESTATUS[0]}
stop_app
echo "poster stopped at $(date -u +%FT%TZ); gap ${GAP}s" | tee "$EVID/gap.txt"
[ "$ARC" -eq 0 ] || { echo '{"status":"FAIL","stage":"post","evidence":"'"$EVID"'"}' | tee "$EVID/result.json"; exit 1; }
sleep "$GAP"

LOGOS_QML_HOT_RELOAD=0 FORUM_DB_PATH="$STATE/b-forum.db" QML_INSPECTOR_PORT=3768 \
  "$UI_DEV" >"$EVID/b-app.log" 2>&1 &
PID=$!; sleep 8
node "$REPO_ROOT/tools/m6_history_driver.mjs" --port 3768 --phase fetch --text "$TEXT" \
  | tee "$EVID/b-driver.json"
BRC=${PIPESTATUS[0]}
stop_app
grep -i -E "history|backfill|store" "$EVID/b-app.log" | grep -v identify | cut -c1-300 | tail -40 > "$EVID/b-history-excerpt.log" || true
STATUS=$([ "$BRC" -eq 0 ] && echo PASS || echo FAIL)
echo '{"status":"'"$STATUS"'","layer":"public-logos.dev-offline-reader","evidence":"'"$EVID"'"}' | tee "$EVID/result.json"
exit "$BRC"
