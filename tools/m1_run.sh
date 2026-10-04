#!/usr/bin/env bash
# LP-0026 Forum — M1 protocol smoke: local Required-transport proof.
#
# Topology: 4 loopback Mix relays (logosctl-hosted) + 2 standalone-app
# instances (sender/receiver) running forum_module with app-owned delivery
# nodes under anonymityLevel=Required (sender).
#
# Proves: Required send over the local Mix path with actual receive at the
# other instance; honest propagation state; cleanup of all owned processes.
# Negative cases (no-Mix refusal, shared-node conflict) run in later slices.
#
# Env:
#   FORUM_STATE   private state root (default ~/.local/share/lp0026-forum-dev/m1-run)
#   PY            python with working `cryptography` (default: python3)
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${FORUM_STATE:-$HOME/.local/share/lp0026-forum-dev/m1-run}"
EVID="$REPO_ROOT/evidence/m1-transport/smoke-$(date +%Y%m%d-%H%M%S)"
PY="${PY:-python3}"
# Harness python must provide `cryptography` (the only third-party dep). Either
# `pip install cryptography`, or use the pinned one from the flake:
#   PY="$(nix build path:$PWD#harness-python --no-link --print-out-paths)/bin/python3"
"$PY" -c 'import cryptography' 2>/dev/null || {
  echo "error: $PY cannot import 'cryptography' (pip install cryptography, or set PY — see above)" >&2
  exit 2
}
RUNTIME="$HOME/.local/share/lp0026-forum-dev/runtime/logosctl-aarch64-macos"
UI_DEV="$REPO_ROOT/result-ui-dev/bin/run-logos-standalone-ui"
MCP="$REPO_ROOT/result-mcp"

mkdir -p "$STATE" "$EVID"
PIDS=()
cleanup() {
  echo "=== cleanup $(date -u +%FT%TZ)"
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  sleep 3
  for pid in "${PIDS[@]:-}"; do
    if ps -p "$pid" >/dev/null 2>&1; then
      echo "SIGKILL $pid"; kill -9 "$pid" 2>/dev/null
    fi
  done
  "$PY" "$REPO_ROOT/tools/m1_topology.py" --state "$STATE/relays" stop 2>/dev/null
  pgrep -fl 'm1-run/relays|run-logos-standalone-ui' \
    && echo "WARNING: leftover smoke-owned processes above" \
    || echo "cleanup verified: no smoke-owned processes remain"
}
trap cleanup EXIT

echo "=== 1/5 start relay topology"
# Never let a previous run's readiness file satisfy the wait below.
rm -f "$STATE/relays/relays.pids"
"$PY" "$REPO_ROOT/tools/m1_topology.py" --state "$STATE/relays" --evidence "$EVID" \
    --runtime "$RUNTIME" start >"$EVID/relays.log" 2>&1 &
RELAY_HARNESS=$!
PIDS+=("$RELAY_HARNESS")
for i in $(seq 1 60); do
  [ -f "$STATE/relays/relays.pids" ] && grep -q core4 "$STATE/relays/relays.pids" && break
  sleep 2
done
[ -f "$STATE/relays/relays.pids" ] || { echo "FAIL: relays did not come up"; exit 1; }
echo "relays up: $(cat "$STATE/relays/relays.pids")"

echo "=== 2/5 app configs"
"$PY" "$REPO_ROOT/tools/m1_topology.py" --state "$STATE/relays" \
    app-config --role sender   --out "$STATE/sender.json"
"$PY" "$REPO_ROOT/tools/m1_topology.py" --state "$STATE/relays" \
    app-config --role receiver --out "$STATE/receiver.json"

echo "=== 3/5 launch two standalone instances"
[ -x "$UI_DEV" ] || { echo "FAIL: build the launcher first: nix build .#ui-dev"; exit 1; }
# Each instance gets its OWN store (the default AppDataLocation is shared by
# two instances of the same app on one host — that would fake the receive).
rm -f "$STATE"/sender-forum.db* "$STATE"/receiver-forum.db*
LOGOS_QML_HOT_RELOAD=0 FORUM_TRANSPORT_CONFIG="$STATE/sender.json" \
  FORUM_DB_PATH="$STATE/sender-forum.db" QML_INSPECTOR_PORT=3768 "$UI_DEV" >"$EVID/sender-app.log" 2>&1 &
PIDS+=($!)
LOGOS_QML_HOT_RELOAD=0 FORUM_TRANSPORT_CONFIG="$STATE/receiver.json" \
  FORUM_DB_PATH="$STATE/receiver-forum.db" QML_INSPECTOR_PORT=3769 "$UI_DEV" >"$EVID/receiver-app.log" 2>&1 &
PIDS+=($!)
sleep 8

echo "=== 4/5 two-instance Required round trip"
LOGOS_QT_MCP="$MCP" node "$REPO_ROOT/tools/m1_ui_driver.mjs" \
  --sender-port 3768 --receiver-port 3769 \
  --text "TECHNICAL TEST DATA: M1 Required-send round trip" \
  --wait 90000 | tee "$EVID/driver-result.json"
DRIVER_RC=${PIPESTATUS[0]}

echo "=== 5/5 verdict"
if [ "$DRIVER_RC" -eq 0 ]; then
  echo '{"status":"PASS","layer":"local-loopback-delivery-mix","evidence":"'"$EVID"'"}' | tee "$EVID/result.json"
else
  echo '{"status":"FAIL","layer":"local-loopback-delivery-mix","evidence":"'"$EVID"'"}' | tee "$EVID/result.json"
fi
exit "$DRIVER_RC"
