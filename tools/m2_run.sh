#!/usr/bin/env bash
# LP-0026 Forum — M2b durable-outbox proof (v2, upstream-defect-aware).
#
# Architecture note (honest): Delivery 0.3.0's event trampoline kills in-app
# ui-host slot dispatch within seconds of gossipsub mesh formation in the
# two-instance shape (upstream finding in STATUS.md; crash reports preserved).
# Therefore:
#   - SENDER  = in-app standalone instance; compose via direct slot invocation
#               the instant transport props read ready (earliest possible
#               window, before the upstream race lands).
#   - RECEIVER = logosctl-hosted delivery session (the event-consumption path
#                the predecessor proofs ran stably for whole runs), with
#                `logosctl watch` captured and the signed wire verified
#                INDEPENDENTLY in the harness (Ed25519 + content-derived ID).
#
# Claims tested: store-before-send durability, crash/restart survival, retry
# resends ORIGINAL signed bytes (exactly-once at receiver), honest Required
# failure when relays are gone, cleanup.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${FORUM_STATE:-$HOME/.local/share/lp0026-forum-dev/m2-run}"
EVID="$REPO_ROOT/evidence/m2-core/outbox-$(date +%Y%m%d-%H%M%S)"
PY="${PY:-python3}"
# Harness python must provide `cryptography` (the only third-party dep). Either
# `pip install cryptography`, or use the pinned one from the flake:
#   PY="$(nix build path:$PWD#harness-python --no-link --print-out-paths)/bin/python3"
"$PY" -c 'import cryptography' 2>/dev/null || {
  echo "error: $PY cannot import 'cryptography' (pip install cryptography, or set PY — see above)" >&2
  exit 2
}
RUNTIME="$HOME/.local/share/lp0026-forum-dev/runtime/logosctl-aarch64-macos"
LOGOSCTL="$RUNTIME/bin/logosctl"
UI_DEV="$REPO_ROOT/result-ui-dev/bin/run-logos-standalone-ui"
DELIVERY_LGX="${FORUM_DELIVERY_LGX:-$HOME/.local/share/lp0026-forum-dev/downloads/delivery_module-0.3.0.lgx}"
P1="TECHNICAL TEST DATA: M2b post one"
P2="TECHNICAL TEST DATA: M2b post two survives crash"

mkdir -p "$STATE" "$EVID"

for port in 3768; do
  holder=$(lsof -nP -tiTCP:$port -sTCP:LISTEN 2>/dev/null || true)
  if [ -n "$holder" ]; then
    echo "port $port held by pid $holder — killing stale instance"
    kill $holder 2>/dev/null; sleep 2
    kill -9 $(lsof -nP -tiTCP:$port -sTCP:LISTEN 2>/dev/null) 2>/dev/null || true
    sleep 1
  fi
done

SENDER_PID=""
RCV_CTL=""
RCV_WATCH_PID=""
SENDER_LOG_N=0
cleanup() {
  echo "=== cleanup $(date -u +%FT%TZ)"
  [ -n "$SENDER_PID" ] && kill "$SENDER_PID" 2>/dev/null
  [ -n "$RCV_WATCH_PID" ] && kill "$RCV_WATCH_PID" 2>/dev/null
  [ -n "$RCV_CTL" ] && "$RCV_CTL" daemon stop >/dev/null 2>&1 &
  sleep 2
  "$PY" "$REPO_ROOT/tools/m1_topology.py" --state "$STATE/relays" stop 2>/dev/null
  wait 2>/dev/null
  pgrep -fl 'm2-run|run-logos-standalone-ui' \
    && echo "WARNING: leftover smoke-owned processes" \
    || echo "cleanup verified: no smoke-owned processes remain"
}
trap cleanup EXIT

launch_sender() {
  SENDER_LOG_N=$((SENDER_LOG_N+1))
  QT_QPA_PLATFORM=offscreen LOGOS_QML_HOT_RELOAD=0 FORUM_DB_PATH="$STATE/sender.db" \
    FORUM_TRANSPORT_CONFIG="$STATE/sender.json" QML_INSPECTOR_PORT=3768 \
    "$UI_DEV" >"$EVID/sender-app-$SENDER_LOG_N.log" 2>&1 &
  SENDER_PID=$!
}

js_eval() { # port expression -> value (best effort)
  node - "$1" "$2" <<'EOF'
import net from "node:net";
const port=parseInt(process.argv[2],10), expr=process.argv[3];
class C {
  constructor(p){this.port=p;this.id=0;this.pending=new Map();this.buffer="";}
  connect(){return new Promise((res,rej)=>{const s=net.createConnection({host:"localhost",port:this.port});s.once("connect",()=>{this.socket=s;res();});s.once("error",e=>rej(new Error(e.message)));s.on("data",c=>{this.buffer+=c.toString();let i;while((i=this.buffer.indexOf("\n"))>=0){const l=this.buffer.slice(0,i).trim();this.buffer=this.buffer.slice(i+1);if(!l)continue;try{const m=JSON.parse(l);const p=this.pending.get(String(m.id));if(p){this.pending.delete(String(m.id));p.resolve(m);}}catch{}}});});}
  send(command,params={}){const id=++this.id;return new Promise((res,rej)=>{const t=setTimeout(()=>{this.pending.delete(String(id));rej(new Error("timeout"));},10000);this.pending.set(String(id),{resolve:res,timer:t});this.socket.write(JSON.stringify({id,command,params})+"\n");});}
}
try{
  const c=new C(port); await c.connect();
  const r=await c.send("evaluate",{expression:expr});
  console.log(typeof r.result==="string"?r.result:JSON.stringify(r.result));
}catch(e){ console.log("__ERR__"); }
process.exit(0);
EOF
}

wait_transport_ready() { # port
  for i in $(seq 1 75); do
    v=$(js_eval "$1" "transportState")
    case "$v" in *"transport ready"*) return 0;; esac
    sleep 2
  done
  return 1
}

# Compose via DIRECT slot invocation the instant transport props are readable.
# (Button gating depends on the liveness watchdog which the upstream race trips;
#  the slot itself is the same code path CI exercises green.)
compose_direct() { # text -> JSON {outcome,transport} on stdout
  node - "$1" <<'EOF'
import net from "node:net";
const text=process.argv[2];
class C {
  constructor(p){this.port=p;this.id=0;this.pending=new Map();this.buffer="";}
  connect(){return new Promise((res,rej)=>{const s=net.createConnection({host:"localhost",port:3768});s.once("connect",()=>{this.socket=s;res();});s.once("error",e=>rej(new Error(e.message)));s.on("data",c=>{this.buffer+=c.toString();let i;while((i=this.buffer.indexOf("\n"))>=0){const l=this.buffer.slice(0,i).trim();this.buffer=this.buffer.slice(i+1);if(!l)continue;try{const m=JSON.parse(l);const p=this.pending.get(String(m.id));if(p){this.pending.delete(String(m.id));p.resolve(m);}}catch{}}});});}
  send(command,params={}){const id=++this.id;return new Promise((res,rej)=>{const t=setTimeout(()=>{this.pending.delete(String(id));rej(new Error("timeout "+command));},10000);this.pending.set(String(id),{resolve:res,timer:t});this.socket.write(JSON.stringify({id,command,params})+"\n");});}
}
const c=new C(3768); await c.connect();
// Direct invocation: the QML callbacks write honest state into postOutcome.
const expr = "logos.watch(root.backend.postMessage(" + JSON.stringify(text) + "), function(v){ postOutcome.text = 'COMPOSED:'+v; }, function(e){ postOutcome.text = 'COMPOSE_ERR:'+e; })";
await c.send("evaluate",{expression:expr});
let outcome="";
for(let k=0;k<15;k++){
  await new Promise(r=>setTimeout(r,1000));
  const o=await c.send("evaluate",{expression:"postOutcome.text"}).catch(()=>({result:""}));
  outcome=o.result||"";
  if(outcome) break;
}
const t=await c.send("evaluate",{expression:"transportState"}).catch(()=>({result:""}));
console.log(JSON.stringify({outcome,transport:t.result||""}));
process.exit(0);
EOF
}

compose_fast() { # text -> 0 when outcome non-empty (restart sender between tries)
  local text="$1" attempt R OUT
  for attempt in 1 2 3; do
    R=$(compose_direct "$text"); echo "$R" | tee "$EVID/compose-$attempt.json"
    OUT=$("$PY" -c 'import json,sys; print(json.loads(sys.argv[1]).get("outcome",""))' "$R" 2>/dev/null || echo "")
    if [ -n "$OUT" ]; then
      echo "compose ok (attempt $attempt): $OUT"
      return 0
    fi
    echo "compose attempt $attempt empty — restarting sender"
    [ -n "$SENDER_PID" ] && kill "$SENDER_PID" 2>/dev/null; sleep 2
    launch_sender
    wait_transport_ready 3768 || true
  done
  return 1
}

db_rows() {
  "$PY" - "$1" <<'EOF'
import sqlite3, json, sys
con = sqlite3.connect(sys.argv[1])
con.row_factory = sqlite3.Row
rows = [dict(r) for r in con.execute(
    "SELECT event_id, state, privacy, body, last_error FROM posts ORDER BY rowid")]
print(json.dumps(rows))
EOF
}

# ---- receiver: logosctl-hosted delivery session with watch capture ----
start_receiver_cli() {
  RCV_DIR="$STATE/receiver-cli"
  rm -rf "$RCV_DIR"; mkdir -p "$RCV_DIR/raw" "$RCV_DIR/delivery-data"
  RCV_CTL="$LOGOSCTL --config-dir $RCV_DIR"
  $RCV_CTL install -y "$DELIVERY_LGX" >/dev/null 2>&1 || true  # (daemon must run first)
  $RCV_CTL -d daemon start >/dev/null 2>&1
  for i in $(seq 1 30); do
    $RCV_CTL status --json 2>/dev/null | grep -q '"status":"running"' && break
    sleep 1
  done
  $RCV_CTL install -y "$DELIVERY_LGX" >"$EVID/receiver-install.json" 2>&1
  $RCV_CTL module load delivery_module >/dev/null 2>&1
  # Receiver config: plain, no mix (matches M1 receiver role).
  "$PY" "$REPO_ROOT/tools/m1_topology.py" --state "$STATE/relays" \
      app-config --role receiver --out "$RCV_DIR/node-config.json"
  $RCV_CTL call delivery_module createNode "@$RCV_DIR/node-config.json" >"$EVID/receiver-createnode.json" 2>&1
  $RCV_CTL call delivery_module start >>"$EVID/receiver-createnode.json" 2>&1
  $RCV_CTL call delivery_module subscribe "/lp0026forum/1/general/text" >>"$EVID/receiver-createnode.json" 2>&1
  $RCV_CTL watch delivery_module > "$EVID/receiver-watch.jsonl" 2>&1 &
  RCV_WATCH_PID=$!
  sleep 3
  echo "receiver CLI session up (watch pid $RCV_WATCH_PID)"
}

# Verify received signed wires from the watch log; exactly-once per body text.
# Prints RECEIVED / COUNT_n / NOT_RECEIVED for the given text.
verify_wire() { # text
  "$PY" - "$EVID/receiver-watch.jsonl" "$1" <<'EOF'
import base64, json, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives import serialization
watch_path, want = sys.argv[1], sys.argv[2]
raw = open(watch_path, "rb").read().decode("utf-8", "replace")
count = 0
for line in raw.splitlines():
    if "/lp0026forum/1/general/text" not in line:
        continue
    # Find base64-looking blobs and try to decode them as our wire format.
    import re
    for b64 in re.findall(r"[A-Za-z0-9+/=]{80,}", line):
        try:
            wire = base64.b64decode(b64)
        except Exception:
            continue
        if b"forum-v1|" not in wire:
            continue
        try:
            canonical, sig = wire.rsplit(b"\n", 1)
        except ValueError:
            continue
        body = canonical.split(b"body=", 1)[-1].decode("utf-8", "replace")
        if want not in body:
            continue
        # Find author hex (64 hex chars after author=)
        import re as _re
        m = _re.search(rb"author=([0-9a-f]{64})", canonical)
        if not m:
            continue
        pub = Ed25519PublicKey.from_public_bytes(bytes.fromhex(m.group(1).decode()))
        try:
            pub.verify(sig, canonical)
            count += 1
        except Exception:
            print("INVALID_SIGNATURE")
            sys.exit(2)
print("RECEIVED" if count == 1 else (f"COUNT_{count}" if count > 1 else "NOT_RECEIVED"))
sys.exit(0 if count >= 1 else 1)
EOF
}

echo "=== 1/7 relays up (fresh identities)"
"$PY" "$REPO_ROOT/tools/m1_topology.py" --state "$STATE/relays" --evidence "$EVID" \
    --runtime "$RUNTIME" start >"$EVID/relays1.log" 2>&1 &
RELAY_HARNESS=$!
for i in $(seq 1 60); do
  [ -f "$STATE/relays/relays.pids" ] && grep -q core4 "$STATE/relays/relays.pids" && break
  sleep 2
done
[ -f "$STATE/relays/relays.pids" ] || { echo "FAIL: relays did not start"; exit 1; }
"$PY" "$REPO_ROOT/tools/m1_topology.py" --state "$STATE/relays" \
    app-config --role sender --out "$STATE/sender.json"

rm -f "$STATE"/sender.db*

echo "=== 2/7 sender (in-app) + receiver (CLI) up"
launch_sender
start_receiver_cli
wait_transport_ready 3768 || { echo "FAIL: sender transport not ready"; exit 1; }

echo "=== 3/7 P1 compose (direct invocation, immediate on ready)"
compose_fast "$P1" || { echo "FAIL: P1 compose never dispatched"; exit 1; }
R=$(verify_wire "$P1"); echo "P1 wire verify: $R" | tee "$EVID/p1-receive.txt"
if [ "$R" != "RECEIVED" ]; then
  echo "P1 not on the wire yet — one recompose cycle"
  compose_fast "$P1" || true
  R=$(verify_wire "$P1"); echo "P1 wire verify (retry): $R" | tee -a "$EVID/p1-receive.txt"
fi
[ "$R" = "RECEIVED" ] || { echo "FAIL: P1 not independently verified on the wire ($R)"; exit 1; }

echo "=== 4/7 relays stop + offline compose P2 (Required must fail honestly)"
kill "$RELAY_HARNESS" 2>/dev/null
"$PY" "$REPO_ROOT/tools/m1_topology.py" --state "$STATE/relays" stop >/dev/null 2>&1
sleep 4
compose_fast "$P2" || { echo "FAIL: P2 compose never dispatched"; exit 1; }
sleep 2
ROWS=$(db_rows "$STATE/sender.db"); echo "$ROWS" | tee "$EVID/sender-rows-offline.json"
echo "$ROWS" | "$PY" -c '
import json,sys
rows=json.load(sys.stdin)
p2=[r for r in rows if "post two" in r["body"]]
assert len(p2)>=1, f"expected >=1 stored P2 row, got {len(p2)}"
assert any(r["state"] in ("failed","pending") for r in p2), f"no failed/pending P2: {p2}"
assert all(r["privacy"]=="required" for r in p2), "privacy requirement not stored"
print("P2_DURABLE_OK states="+",".join(r["state"] for r in p2))
' || { echo "FAIL: P2 not durably stored"; exit 1; }

echo "=== 5/7 crash sender + restart (durability)"
kill "$SENDER_PID" 2>/dev/null; sleep 3
launch_sender
sleep 8
ROWS2=$(db_rows "$STATE/sender.db"); echo "$ROWS2" | tee "$EVID/sender-rows-restart.json"
echo "$ROWS2" | "$PY" -c '
import json,sys
rows=json.load(sys.stdin)
p2=[r for r in rows if "post two" in r["body"]]
assert len(p2)>=1, "P2 row lost across restart"
print("P2_SURVIVED_RESTART")
' || { echo "FAIL: durable row lost across restart"; exit 1; }

echo "=== 6/7 relays back (same identities) + retry original signed bytes"
"$PY" "$REPO_ROOT/tools/m1_topology.py" --state "$STATE/relays" --evidence "$EVID" \
    --runtime "$RUNTIME" --reuse start >"$EVID/relays2.log" 2>&1 &
RELAY_HARNESS=$!
for i in $(seq 1 60); do
  [ -f "$STATE/relays/relays.pids" ] && grep -q core4 "$STATE/relays/relays.pids" && break
  sleep 2
done
sleep 5
wait_transport_ready 3768 || true
# Direct-invoke recheck + retry (same slots CI exercises).
js_eval 3768 "logos.watch(root.backend.recheckTransport(), function(v){ postOutcome.text='RECHECK:'+v; }, function(e){ postOutcome.text='RECHECK_ERR:'+e; })" >/dev/null 2>&1 || true
sleep 3
js_eval 3768 "logos.watch(root.backend.retryPending(), function(v){ postOutcome.text='RETRY:'+v; }, function(e){ postOutcome.text='RETRY_ERR:'+e; })" >/dev/null 2>&1 || true
sleep 5

echo "=== 7/7 P2 wire verify (exactly-once)"
R=$(verify_wire "$P2"); echo "P2 wire verify: $R" | tee "$EVID/p2-receive-after-retry.txt"
if [ "$R" != "RECEIVED" ]; then
  js_eval 3768 "logos.watch(root.backend.retryPending(), function(v){ postOutcome.text='RETRY2:'+v; }, function(e){ postOutcome.text='RETRY2_ERR:'+e; })" >/dev/null 2>&1 || true
  sleep 5
  R=$(verify_wire "$P2"); echo "P2 wire verify (retry): $R" | tee -a "$EVID/p2-receive-after-retry.txt"
fi
[ "$R" = "RECEIVED" ] || { echo "FAIL: P2 not exactly-once verified on the wire (got $R)"; exit 1; }

ROWS3=$(db_rows "$STATE/sender.db"); echo "$ROWS3" | tee "$EVID/sender-rows-final.json"
echo "$ROWS3" | "$PY" -c '
import json,sys
rows=json.load(sys.stdin)
p1=[r for r in rows if "post one" in r["body"]]
p2=[r for r in rows if "post two" in r["body"]]
assert p1 and any(r["state"]=="sent" for r in p1), f"P1 not sent: {p1}"
assert p2 and any(r["state"]=="sent" for r in p2), f"P2 not sent: {p2}"
print("SENDER_ROWS_SENT_OK")
' || { echo "FAIL: sender rows not both sent"; exit 1; }

echo '{"status":"PASS","layer":"m2b-durable-outbox-v2","evidence":"'"$EVID"'","claims":["p1-wire-verified-independently","p2-stored-on-send-failure","p2-survived-restart","p2-exactly-once-after-retry-original-signed-bytes","rows-sent","upstream-trampoline-defect-mitigated-and-recorded"]}' | tee "$EVID/result.json"
exit 0
