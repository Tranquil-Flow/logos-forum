#!/usr/bin/env bash
# LP-0026 Forum — live public-network round trip (logos.dev, Mix Required).
#
# Two standalone-app instances start WITHOUT any transport config; each joins
# the public logos.dev network only through the in-app "Connect to Logos
# network" action. A posts; B must render it [received]. This publishes one
# clearly-labelled TECHNICAL TEST DATA post to the public network.
#
# Env: FORUM_STATE (default ~/.local/share/lp0026-forum-dev/m6-live)
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${FORUM_STATE:-$HOME/.local/share/lp0026-forum-dev/m6-live}"
EVID="$REPO_ROOT/evidence/m6-live/live-$(date +%Y%m%d-%H%M%S)"
UI_DEV="$REPO_ROOT/result-ui-dev/bin/run-logos-standalone-ui"
MCP="$REPO_ROOT/result-mcp"
mkdir -p "$STATE" "$EVID"
[ -x "$UI_DEV" ] || { echo "FAIL: build the launcher first: nix build .#ui-dev"; exit 1; }
for p in 3768 3769; do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "FAIL: port $p busy"; exit 1; fi
done

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  sleep 3
  for pid in "${PIDS[@]:-}"; do
    ps -p "$pid" >/dev/null 2>&1 && { echo "SIGKILL $pid"; kill -9 "$pid" 2>/dev/null; }
  done
  pgrep -fl 'run-logos-standalone-ui' \
    && echo "WARNING: leftover app processes above" \
    || echo "cleanup verified: no live-run processes remain"
}
trap cleanup EXIT

rm -f "$STATE"/a-forum.db* "$STATE"/b-forum.db*
unset FORUM_TRANSPORT_CONFIG
LOGOS_QML_HOT_RELOAD=0 FORUM_DB_PATH="$STATE/a-forum.db" QML_INSPECTOR_PORT=3768 \
  "$UI_DEV" >"$EVID/a-app.log" 2>&1 &
PIDS+=($!)
LOGOS_QML_HOT_RELOAD=0 FORUM_DB_PATH="$STATE/b-forum.db" QML_INSPECTOR_PORT=3769 \
  "$UI_DEV" >"$EVID/b-app.log" 2>&1 &
PIDS+=($!)
sleep 8

LOGOS_QT_MCP="$MCP" node "$REPO_ROOT/tools/m6_live_driver.mjs" --a-port 3768 --b-port 3769 \
  --text "TECHNICAL TEST DATA: live logos.dev round trip $(date -u +%FT%TZ)" \
  "$@" | tee "$EVID/driver-result.json"
RC=${PIPESTATUS[0]}
grep -E -i "mix|propagat|lightpush|peer|error|listen" "$EVID/a-app.log" | tail -60 > "$EVID/a-transport-excerpt.log" || true
STATUS=$([ "$RC" -eq 0 ] && echo PASS || echo FAIL)
echo '{"status":"'"$STATUS"'","layer":"public-logos.dev-mix-required","evidence":"'"$EVID"'"}' | tee "$EVID/result.json"
exit "$RC"
