#!/usr/bin/env bash
# LP-0026 Forum — in-app Logos Storage snapshot test.
# A (author) joins logos.dev, posts two TECHNICAL TEST DATA posts through Mix,
# presses "Save snapshot" and the announcement (CID + where to fetch it) goes
# out through Mix. B is a fresh reader that never joins Delivery: it restores
# from the announcement text alone, so every post it shows came through
# Logos Storage and passed signature verification.
# Storage layer: two Storage nodes on loopback (127.0.0.1, no public
# bootstrap) so both instances can run on one host; Delivery layer: public
# logos.dev.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${FORUM_STATE:-$HOME/.local/share/lp0026-forum-dev/m7-storage}"
EVID="$REPO_ROOT/evidence/m7-storage/snapshot-$(date +%Y%m%d-%H%M%S)"
UI_DEV="$REPO_ROOT/result-ui-dev/bin/run-logos-standalone-ui"
mkdir -p "$STATE" "$EVID"
[ -x "$UI_DEV" ] || { echo "FAIL: build the launcher first: nix build .#ui-dev"; exit 1; }
for p in 3768 3769; do
  lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 && { echo "FAIL: port $p busy"; exit 1; }
done
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  sleep 3
  for pid in "${PIDS[@]:-}"; do
    ps -p "$pid" >/dev/null 2>&1 && { echo "SIGKILL $pid"; kill -9 "$pid" 2>/dev/null; }
  done
  pgrep -fl 'run-logos-standalone-ui' && echo "WARNING: leftover app processes" \
    || echo "cleanup verified: no storage-run processes remain"
}
trap cleanup EXIT

rm -rf "$STATE"/a-* "$STATE"/b-*
storage_cfg() {  # role port
  mkdir -p "$STATE/$1-storage"
  cat > "$STATE/$1-storage.json" <<EOF
{"data-dir":"$STATE/$1-storage","log-level":"info","log-file":"$STATE/$1-storage.log",
 "listen-ip":"127.0.0.1","listen-port":$2,"nat":"extip:127.0.0.1",
 "no-bootstrap-node":true,"bootstrap-node":[],"mix-enabled":false,"num-threads":0,
 "storage-quota":67108864,"block-ttl":"24h","block-mi":"1m"}
EOF
}
storage_cfg a 8571
storage_cfg b 8572
cp "$STATE/a-storage.json" "$STATE/b-storage.json" "$EVID/"
unset FORUM_TRANSPORT_CONFIG
TEXT="TECHNICAL TEST DATA: storage snapshot check $(date -u +%FT%TZ)"

LOGOS_QML_HOT_RELOAD=0 FORUM_DB_PATH="$STATE/a-forum.db" FORUM_STORAGE_CONFIG="$STATE/a-storage.json" FORUM_ALLOW_PRIVATE_PEERS=1 \
  QML_INSPECTOR_PORT=3768 "$UI_DEV" >"$EVID/a-app.log" 2>&1 &
PIDS+=($!); sleep 8
node "$REPO_ROOT/tools/m7_storage_driver.mjs" --port 3768 --phase save --text "$TEXT" \
  | tee "$EVID/a-driver.json"
ARC=${PIPESTATUS[0]}
if [ "$ARC" -ne 0 ]; then
  echo '{"status":"FAIL","stage":"save","evidence":"'"$EVID"'"}' | tee "$EVID/result.json"; exit 1
fi
ANN="$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(r.announcement)' "$EVID/a-driver.json")"

# The reader starts only now, with an empty store and no Delivery node.
LOGOS_QML_HOT_RELOAD=0 FORUM_DB_PATH="$STATE/b-forum.db" FORUM_STORAGE_CONFIG="$STATE/b-storage.json" FORUM_ALLOW_PRIVATE_PEERS=1 \
  QML_INSPECTOR_PORT=3769 "$UI_DEV" >"$EVID/b-app.log" 2>&1 &
PIDS+=($!); sleep 8
node "$REPO_ROOT/tools/m7_storage_driver.mjs" --port 3769 --phase restore --text "$TEXT" \
  --announcement "$ANN" | tee "$EVID/b-driver.json"
BRC=${PIPESTATUS[0]}
ls -la "$STATE"/a-forum-snapshots "$STATE"/b-forum-snapshots > "$EVID/snapshot-files.txt" 2>&1 || true
cp "$STATE/a-storage.log" "$STATE/b-storage.log" "$EVID/" 2>/dev/null || true
STATUS=$([ "$BRC" -eq 0 ] && echo PASS || echo FAIL)
echo '{"status":"'"$STATUS"'","layer":"in-app-storage-loopback+delivery-logos.dev","evidence":"'"$EVID"'"}' | tee "$EVID/result.json"
exit "$BRC"
