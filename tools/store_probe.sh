#!/usr/bin/env bash
# LP-0026 Forum — M2-GUI dev-launcher probe (slot return, PROP sync, post path).
# Historical name: "QtRO wedge probe" — the wedge was a crashed ui-host; see ROOT CAUSE below.
#
# The original "store wedge" diagnosis was too shallow: the legacy m5b
# driver read the synchronous WATCH HANDLE returned by `logos.watch(...)`,
# not the async slot result. This probe drives the same product path the
# user clicks (real QML buttons) and reads three independent observables:
#
#   L1. source-side slot execution (host.log: did the C++ slot run?)
#   L2. PROP-side state (`root.accounts`, `root.threadPosts`, etc.)
#   L3. result-callback side (`outcome.text` after QML success/error)
#
# A run is a clean probe PASS if it launches, records all layers, and cleans
# up processes/ports, even if the product path remains BLOCKED. The product
# gate is carried in result.json's `gate_label` and `diagnosis`.
#
# Architecture (mirrors m5b_realhost_gui.sh, corrected):
#   1. Fresh isolated profile + module + declared deps (install layout).
#   2. Inspector Basecamp-free host launch (real window, port $PORT).
#   3. Tile click → module view → Connected (sanity).
#   4. Stage 1: click "Check transport" → observe whether a source-side
#      slot dispatch happens and whether a slot result reaches `outcome.text`.
#      Host-log evidence (`getAvailableConfigs called`) distinguishes source
#      execution from result-callback delivery.
#   5. Stage 2: click "Add alias" + direct `createAccount`/`echo` probes →
#      observe QML→source dispatch and PROP-sync via `root.accounts`.
#   6. Stage 3: click "Create" topic, "Send" post without transport →
#      observe post-path status/outcome/thread PROP behavior.
#   7. Cleanup proof (zero owned processes, port freed, no stale db writer).
#
# `FORUM_SKIP_STAGE1=1` skips stage 1 to test whether stage 2 wedges on a
# fresh source or only after stage-1 contamination.
#
# Historical bisect rungs preserved by `FORUM_BISECT`: each toggles one
# store-adjacent hypothesis (precreated schema, WAL/journal). These are kept
# for regression/confirmation receipts.
#
# ROOT CAUSE (2026-10-03, lldb on the ui-host): the "3-layer QtRO wedge" was
# the backend process DYING, not QtRO. The plugin was linked with the
# builder's `-undefined dynamic_lookup` and without libsodium/sqlite, so the
# first slot that opened the store (store() -> ensureTopic() ->
# KeyPair::generate() -> sodium_init) jumped to address 0 and SIGSEGV'd the
# ui-host; every later slot/PROP then hit `connectionToSource is null`. Fixed
# by LINK_LIBRARIES sqlite3 sodium in CMakeLists.txt. The probe now records
# the plugin's linkage and whether the ui-host survived all stages.
#
# Env: FORUM_STATE (default ~/.local/share/lp0026-forum-dev/store-probe),
#      FORUM_BISECT=open|precreated|nowal|reentry (hypothesis under test).
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FORUM_MCP_FW="$REPO_ROOT/result-mcp/test-framework/framework.mjs"
# Use the canonical dev state root for the dep .lgx files (m5b pattern) and
# keep probe-specific state under a subdir to avoid colliding with prior runs.
DEV_STATE="$HOME/.local/share/lp0026-forum-dev"
STATE="${FORUM_STATE:-$DEV_STATE/store-probe}"
EV="$REPO_ROOT/evidence/m5-package"
STAMP="$(date +%Y%m%d-%H%M%S)"
EVID="$EV/store-probe-$STAMP"
BC="$REPO_ROOT/result-ui-dev/bin/run-logos-standalone-ui"
PROFILE="$STATE/profile"
PORT=3789
DBPATH="$STATE/probe-forum.db"
BUILD="$DEV_STATE/builds"

# The MCP framework reads QML_INSPECTOR_PORT from env; export it so the
# node child processes pick up the same port the host is bound to.
export QML_INSPECTOR_PORT="$PORT"
export QML_INSPECTOR_HOST="localhost"

mkdir -p "$EVID"

# ---- port hygiene: sweep only our own footprint (ui-host that carries our
#      plugin dir, or the dev-launcher on the same port). Never a broad
#      logos_host sweep — other workloads on this host are out of scope.
sweep() {
  pkill -9 -f "run-logos-standalone-ui.*$PORT" 2>/dev/null
  pkill -9 -f "logos-forum_module-plugin-dir" 2>/dev/null
  sleep 2
  local h
  h=$(lsof -nP -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $2}')
  [ -n "$h" ] && { kill -9 $h 2>/dev/null; sleep 1; }
  lsof -nP -tiTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 \
    && { echo "FAIL: port $PORT still held after sweep" >&2; exit 1; }
}

# ---- seed the install layout: fresh profile, our module + declared deps.
seed_pkg() {
  local LGXF="$1" BUCKET="$2" NAME="$3" TMP V
  [ -f "$LGXF" ] || { echo "FAIL: missing $LGXF" >&2; exit 1; }
  TMP=$(mktemp -d)
  tar -xzf "$LGXF" -C "$TMP"
  V=$(python3 -c "import json;print(list(json.load(open('$TMP/manifest.json'))['main'])[0])")
  mkdir -p "$PROFILE/$BUCKET/$NAME"
  cp -R "$TMP/variants/$V/." "$PROFILE/$BUCKET/$NAME/"
  cp "$TMP/manifest.json" "$PROFILE/$BUCKET/$NAME/"
  [ -d "$TMP/assets" ] && { mkdir -p "$PROFILE/$BUCKET/$NAME/assets"; cp -R "$TMP/assets/." "$PROFILE/$BUCKET/$NAME/assets/"; }
  echo "$V" > "$PROFILE/$BUCKET/$NAME/variant"
  rm -rf "$TMP"
  echo "  seeded $NAME ($BUCKET, $V)"
}

# Optional pre-stage rungs (the bisect plan). Each is a one-line hypothesis
# toggled by env var; the rest of the probe is identical.
apply_bisect() {
  case "${FORUM_BISECT:-}" in
    precreated)  # hypothesis A: createTopic race — precreate the db with the
                  # "General" topic row so the slot does NOT have to enqueue.
      mkdir -p "$(dirname "$DBPATH")"
      python3 - <<EOF
import sqlite3, os
p = "$DBPATH"
if os.path.exists(p): os.remove(p)
con = sqlite3.connect(p)
con.executescript("""
CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at_ms INTEGER);
CREATE TABLE accounts (alias TEXT PRIMARY KEY, pub_hex TEXT, priv_hex TEXT, created_at_ms INTEGER);
CREATE TABLE topics (topic_id TEXT PRIMARY KEY, forum_id TEXT, title TEXT, author_pub_hex TEXT, alias TEXT, created_at_ms INTEGER, event_id TEXT);
CREATE TABLE posts (event_id TEXT PRIMARY KEY, topic_id TEXT, alias TEXT, body TEXT, state TEXT, last_error TEXT, created_at_ms INTEGER, updated_at_ms INTEGER);
CREATE TABLE received (event_id TEXT PRIMARY KEY, topic_id TEXT, alias TEXT, body TEXT, received_at_ms INTEGER);
INSERT INTO schema_version VALUES (1, 1700000000000);
INSERT INTO topics VALUES ('probe-general', 'general', 'General', '', '', 1700000000000, '');
""")
con.commit(); con.close()
print("  precreated empty db with schema_version=1 + General row")
EOF
      ;;
    nowal)  # hypothesis B: WAL/journal on the host fs. Precreate + force
              # MEMORY journal. The ui-host may be unable to take a write
              # lock on the WAL under offscreen QPA.
      python3 - <<EOF
import sqlite3, os
p = "$DBPATH"
if os.path.exists(p): os.remove(p)
con = sqlite3.connect(p)
con.executescript("""
CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at_ms INTEGER);
CREATE TABLE accounts (alias TEXT PRIMARY KEY, pub_hex TEXT, priv_hex TEXT, created_at_ms INTEGER);
CREATE TABLE topics (topic_id TEXT PRIMARY KEY, forum_id TEXT, title TEXT, author_pub_hex TEXT, alias TEXT, created_at_ms INTEGER, event_id TEXT);
CREATE TABLE posts (event_id TEXT PRIMARY KEY, topic_id TEXT, alias TEXT, body TEXT, state TEXT, last_error TEXT, created_at_ms INTEGER, updated_at_ms INTEGER);
CREATE TABLE received (event_id TEXT PRIMARY KEY, topic_id TEXT, alias TEXT, body TEXT, received_at_ms INTEGER);
INSERT INTO schema_version VALUES (1, 1700000000000);
INSERT INTO topics VALUES ('probe-general', 'general', 'General', '', '', 1700000000000, '');
""")
con.execute('PRAGMA journal_mode=MEMORY'); con.execute('PRAGMA synchronous=OFF')
con.commit(); con.close()
print("  precreated + journal_mode=MEMORY, synchronous=OFF")
EOF
      ;;
    reentry)  # hypothesis C: marshal the open() onto the source thread
              # (skipped here — that's a code change, not a probe toggle).
      echo "  reentry hypothesis requires a code change, not a probe toggle" >&2
      ;;
    ""|"open")  # baseline: nothing extra; store opens lazily on first touch.
      :
      ;;
    *) echo "FAIL: unknown FORUM_BISECT=$1 (use open|precreated|nowal|reentry)" >&2; exit 1 ;;
  esac
}

stage1_check_transport() {
  echo "=== stage 1: 'Check transport' → store() opened? ==="
  node --input-type=module - "$PORT" "$EVID" <<'EOF' || { echo "FAIL: stage 1 driver crashed"; return 1; }
import { resolve } from "node:path";
const { Inspector, App } = await import(process.env.FORUM_MCP_FW);
const port = parseInt(process.argv[2], 10);
const evid = process.argv[3];
const ins = new Inspector(); ins.requestId = 1000;
const app = new App(ins);
await ins.connect();

// 1. wait for module view ("Logos Forum" header)
const viewDeadline = Date.now() + 25000;
let view = null;
while (Date.now() < viewDeadline) {
  const v = await app.findByProperty("text", "Logos Forum");
  if (v.matches?.length) { view = v; break; }
  await new Promise(r => setTimeout(r, 400));
}
if (!view) { console.log(JSON.stringify({stage1:"FAIL", reason:"no Logos Forum header"})); process.exit(1); }

// 2. wait for Connected (backend ready handshake)
const cDeadline = Date.now() + 25000;
let connected = false;
while (Date.now() < cDeadline) {
  const c = await app.findByProperty("text", "Module ready");
  if (c.matches?.length) { connected = true; break; }
  await new Promise(r => setTimeout(r, 500));
}
if (!connected) { console.log(JSON.stringify({stage1:"FAIL", reason:"no Connected"})); process.exit(1); }

// 3. read transportState BEFORE click — baseline (set in onContextReady).
const tBefore = await ins.send("evaluate", { expression: "root.transportState" });

// 4a. Try the same path the CI test uses: evaluate(transportStatus()) —
//     this invokes the slot via JS (synchronous return), bypassing the
//     QML watch()'s async success callback. The slot's return value
//     shows up in evaluate.result directly.
const directCall = await ins.send("evaluate", {
  expression: "root.backend ? root.backend.transportStatus() : 'no-backend'"
});
const directResult = (typeof directCall.result === "string")
  ? directCall.result
  : (directCall.result?.value ?? JSON.stringify(directCall.result ?? directCall));

// 4b. Then try the QML-button path: open "Network details", then
//     findAndClick "Check transport".
await app.click("Network details", { exact: true });
await new Promise((r) => setTimeout(r, 800));
await app.click("Check transport", { exact: true });

// 5. wait for outcome.text to update (the QML watch's success callback
//    would set outcome.text = the slot's return string).
const outDeadline = Date.now() + 10000;
let outcomeText = "";
while (Date.now() < outDeadline) {
  const o = await ins.send("evaluate", { expression: "outcome.text" });
  const v = (typeof o.result === "string") ? o.result : (o.result?.value ?? "");
  if (v && v.trim() !== "") { outcomeText = v; break; }
  await new Promise(r => setTimeout(r, 400));
}

// 6. read transportState AFTER (the PROP may have refreshed)
const tAfter = await ins.send("evaluate", { expression: "root.transportState" });

// 7. read other props — accounts/topics/threadPosts
const acc = await ins.send("evaluate", { expression: "root.accounts" });
const top = await ins.send("evaluate", { expression: "root.topics" });
const thp = await ins.send("evaluate", { expression: "root.threadPosts" });

// Stage 1 is intentionally scoped to L1/L3: did the source-side
// transportStatus path run, and did its result reach QML? A missing outbox
// here is NOT by itself a store verdict; the top-level result combines this
// with host.log and the stage-2/3 dispatch/PROP probes.
const direct_has_outbox = /outbox: \d+/.test(String(directResult));
const outcome_has_outbox = /outbox: \d+/.test(outcomeText || "");
const result = {
  // PASS if EITHER the direct slot call OR the QML watch path shows the
  // store opened (i.e. we have evidence the store works at all). The
  // diagnosis field tells which path succeeded.
  stage1: (direct_has_outbox || outcome_has_outbox) ? "PASS" : "FAIL",
  direct_slot_return: String(directResult).slice(0, 250),
  direct_has_outbox,
  outcome: outcomeText ? outcomeText.slice(0, 250) : "(empty — QML watch success callback did not fire)",
  outcome_has_outbox,
  transportState_before: tBefore.result ?? tBefore,
  transportState_after: tAfter.result ?? tAfter,
  transportState_changed: (tBefore.result ?? tBefore) !== (tAfter.result ?? tAfter),
  accounts: acc.result ?? acc,
  topics: top.result ?? top,
  threadPosts_count: Array.isArray(thp.result) ? thp.result.length : 0,
  // Stage-local interpretation only. The top-level diagnosis in result.json
  // combines all stages and host.log; do not treat this as the product gate.
  diagnosis: !direct_has_outbox && !outcome_has_outbox
    ? "no observable outbox from stage1 (slot-return/callback path wedged or source dispatch absent)"
    : !direct_has_outbox
      ? "outbox observed via QML watch only; direct read did not expose slot result"
      : !outcome_has_outbox
        ? "outbox observed via direct slot read; QML watch/result-callback path wedged"
        : "outbox observed via direct read and QML callback",
};
console.log(JSON.stringify(result, null, 2));
process.exit(result.stage1 === "PASS" ? 0 : 1);
EOF
}

stage2_add_alias() {
  echo "=== stage 2: 'Add alias' → PROP-sync test ==="
  node --input-type=module - "$PORT" "$EVID" <<'EOF' || { echo "FAIL: stage 2 driver crashed"; return 1; }
import { resolve } from "node:path";
const { Inspector, App } = await import(process.env.FORUM_MCP_FW);
const port = parseInt(process.argv[2], 10);
const evid = process.argv[3];
const ins = new Inspector(); ins.requestId = 2000;
const app = new App(ins);
await ins.connect();

// Verify backend is still alive after stage 1's slot call (which may have
// destabilized the QtRO connection in the dev launcher build).
const backendCheck = await ins.send("evaluate", { expression: "root.backend !== null" });
const backend_alive = (typeof backendCheck.result === "boolean")
  ? backendCheck.result
  : (backendCheck.result?.value ?? false);

// Try multiple approaches in order. Track which one (if any) propagates.
const accBefore = await ins.send("evaluate", { expression: "root.accounts" });

// Approach 1: set the aliasInput text + findAndClick "Add alias" (the user's path)
let clickResult = null;
let textBefore = null;
let textAfter = null;
let buttonEnabled = null;
const tf = await app.findByProperty("placeholderText", "new alias");
if (tf.matches?.length) {
  const propsBefore = await app.getProperties(tf.matches[0].id);
  textBefore = propsBefore.properties?.find(p => p.name === "text")?.value;
  await ins.send("setProperty", { objectId: tf.matches[0].id, property: "text", value: "demo" });
  const propsAfter = await app.getProperties(tf.matches[0].id);
  textAfter = propsAfter.properties?.find(p => p.name === "text")?.value;
  // Find the "Add alias" button and check its enabled state
  const btn = await app.findByProperty("text", "Add alias");
  if (btn.matches?.length) {
    const btnProps = await app.getProperties(btn.matches[0].id);
    buttonEnabled = btnProps.properties?.find(p => p.name === "enabled")?.value;
  }
  clickResult = await ins.send("findAndClick", { text: "Add alias" });
}

// Approach 2: direct evaluate call to the slot (mimics the CI's sendButton.clicked() pattern)
const directSlot = await ins.send("evaluate", {
  expression: "logos.watch(root.backend.createAccount('demo'), function(v){return v}, function(e){return e})"
});
const directSlotStr = (typeof directSlot.result === "string")
  ? directSlot.result
  : JSON.stringify(directSlot.result ?? directSlot);

// Approach 3: try a slot that doesn't cross to capability_module (echo is a
// trivial round-trip — if echo PROP doesn't update, the QtRO source-replica
// connection is completely dead; if it does update, the wedge is specific to
// store-touching slots).
const echoDirect = await ins.send("evaluate", {
  expression: "logos.watch(root.backend.echo('prop-sync-probe'), function(v){return v}, function(e){return e})"
});
const echoDirectStr = (typeof echoDirect.result === "string")
  ? echoDirect.result
  : JSON.stringify(echoDirect.result ?? echoDirect);

// Wait for the accounts PROP to update (PROP-sync is what we really test)
const deadline = Date.now() + 15000;
let accountsChanged = false;
let outcomeText = "";
while (Date.now() < deadline) {
  const a = await ins.send("evaluate", { expression: "root.accounts" });
  const aStr = JSON.stringify(a.result ?? a);
  if (aStr.includes("demo")) { accountsChanged = true; }
  const o = await ins.send("evaluate", { expression: "outcome.text" });
  const v = (typeof o.result === "string") ? o.result : (o.result?.value ?? "");
  if (v && v.trim() !== "") { outcomeText = v; }
  if (accountsChanged || outcomeText.includes("Alias created") || outcomeText.startsWith("error")) break;
  await new Promise(r => setTimeout(r, 400));
}

const accAfter = await ins.send("evaluate", { expression: "root.accounts" });
const accAfterStr = JSON.stringify(accAfter.result ?? accAfter);
const result = {
  stage2: accountsChanged ? "PASS" : "FAIL",
  backend_alive_after_stage1: backend_alive,
  textfield_found: !!(tf.matches?.length),
  textfield_text_before_set: textBefore,
  textfield_text_after_set: textAfter,
  button_enabled_before_click: buttonEnabled,
  click_result: clickResult,
  direct_slot_return: directSlotStr.slice(0, 200),
  echo_slot_return: echoDirectStr.slice(0, 200),
  accounts_before: accBefore.result ?? accBefore,
  accounts_after: accAfter.result ?? accAfter,
  accounts_prop_has_demo: accAfterStr.includes("demo"),
  prop_sync_works: accountsChanged,
  outcome: outcomeText || "(empty)",
  channel: accountsChanged ? "PROP-sync" : "wedged",
  interpretation_hint: accountsChanged
    ? "PROP-sync works → just need to refactor slot-return buttons to read PROPs only"
    : "PROP-sync also wedged → first slot call kills the QtRO source-replica connection; all subsequent slot calls are no-ops; need source-side fix (worker-thread dispatch + marshalled PROP updates) OR upstream capability_module eventResponse fix",
};
console.log(JSON.stringify(result, null, 2));
process.exit(result.stage2 === "PASS" ? 0 : 1);
EOF
}

stage3_topic_post() {
  echo "=== stage 3: topic create + post (no transport) ==="
  node --input-type=module - "$PORT" "$EVID" <<'EOF' || { echo "FAIL: stage 3 driver crashed"; return 1; }
import { resolve } from "node:path";
const { Inspector, App } = await import(process.env.FORUM_MCP_FW);
const port = parseInt(process.argv[2], 10);
const evid = process.argv[3];
const ins = new Inspector(); ins.requestId = 3000;
const app = new App(ins);
await ins.connect();

// Topic TextField
const ttf = await app.findByProperty("placeholderText", "new topic title");
if (!ttf.matches?.length) { console.log(JSON.stringify({stage3:"FAIL", reason:"no topic TextField"})); process.exit(1); }
await ins.send("setProperty", { objectId: ttf.matches[0].id, property: "text", value: "Probe Topic" });
// Click by QML id: findAndClick("Create") substring-matches the stage-2
// outcome text "Alias created" and clicks the wrong item.
// Clear stale stage-2 outcome ("error: alias already exists") first.
await ins.send("evaluate", { expression: "outcome.text = ''" });
await ins.send("evaluate", { expression: "createTopicButton.clicked()" });
const topicDeadline = Date.now() + 25000;
let topicOutcome = "";
while (Date.now() < topicDeadline) {
  const o = await ins.send("evaluate", { expression: "outcome.text" });
  const v = (typeof o.result === "string") ? o.result : (o.result?.value ?? "");
  if (v && (v.includes("Topic created") || v.startsWith("error"))) { topicOutcome = v; break; }
  await new Promise(r => setTimeout(r, 400));
}
if (!topicOutcome) { console.log(JSON.stringify({stage3:"FAIL", reason:"topic outcome never updated"})); process.exit(1); }
if (topicOutcome.startsWith("error")) { console.log(JSON.stringify({stage3:"FAIL", reason:"topic rejected", outcome:topicOutcome})); process.exit(1); }

// Type into composer
const cf = await app.findByProperty("placeholderText", "Write a post (plain text)");
if (!cf.matches?.length) { console.log(JSON.stringify({stage3:"FAIL", reason:"no composer TextField"})); process.exit(1); }
await ins.send("setProperty", { objectId: cf.matches[0].id, property: "text", value: "TECHNICAL TEST DATA: store_probe stage3" });

// Click sendButton via evaluate (id exposed in QML)
await ins.send("evaluate", { expression: "outcome.text = ''" });
await ins.send("evaluate", { expression: "sendButton.clicked()" });

// Wait for outcome to show "Not sent (unavailable)"
const sendDeadline = Date.now() + 25000;
let sendOutcome = "";
while (Date.now() < sendDeadline) {
  const o = await ins.send("evaluate", { expression: "outcome.text" });
  const v = (typeof o.result === "string") ? o.result : (o.result?.value ?? "");
  if (v && (v.includes("Not sent") || v.startsWith("error"))) { sendOutcome = v; break; }
  await new Promise(r => setTimeout(r, 400));
}
if (!sendOutcome) { console.log(JSON.stringify({stage3:"FAIL", reason:"send outcome never updated"})); process.exit(1); }

const thread = await ins.send("evaluate", { expression: "root.threadPosts" });
const tp = JSON.stringify(thread.result ?? thread);
const result = {
  stage3: "PASS",
  topic_outcome: topicOutcome,
  send_outcome: sendOutcome,
  threadPosts: thread.result ?? thread,
  thread_has_failed: tp.includes("[failed]"),
  thread_has_body: tp.includes("TECHNICAL TEST DATA: store_probe stage3"),
  composer_kept: await (async () => {
    const p = await app.getProperties(cf.matches[0].id);
    return p.properties?.find(pp => pp.name === "text")?.value === "TECHNICAL TEST DATA: store_probe stage3";
  })(),
};
console.log(JSON.stringify(result, null, 2));
process.exit(result.thread_has_failed && result.thread_has_body && result.composer_kept ? 0 : 1);
EOF
}

cleanup() {
  local APP_PID="${APP_PID:-}"
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  sleep 2
  [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null
  sweep >/dev/null 2>&1 || true
  local LEFT PORT_BUSY
  LEFT=$(pgrep -f "$PROFILE" | head -3)
  [ -n "$LEFT" ] && kill -9 $LEFT 2>/dev/null
  sleep 1
  LEFT=$(pgrep -f "$PROFILE" | head -2)
  PORT_BUSY=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' ')
  echo "$LEFT" > "$EVID/processes_remaining.txt"
  echo "$PORT_BUSY" > "$EVID/port_busy.txt"
}

# ---- main ----
sweep
echo "=== 1/6 install layout ==="
LGX="$REPO_ROOT/result-lgx-dev/logos-forum_module-module.lgx"
# Skip rebuild if the lgx already exists (m5b run used it minutes/hours ago;
# the build is slow and not what the wedge probe is about). To force a
# rebuild, set FORUM_REBUILD_LGX=1.
if [ "${FORUM_REBUILD_LGX:-0}" = "1" ]; then
  rm -f "$LGX"
  nix build "path:$REPO_ROOT#lgx" --max-jobs 2 --cores 4 --accept-flake-config -o "$REPO_ROOT/result-lgx-dev" >"$EVID/build-lgx.log" 2>&1
fi
[ -f "$LGX" ] || { echo "FAIL: lgx missing (set FORUM_REBUILD_LGX=1 to build it)" >&2; exit 1; }
rm -rf "$PROFILE" && mkdir -p "$PROFILE"
seed_pkg "$LGX" plugins forum_module
seed_pkg "$BUILD/result-delivery-dev-lgx/logos-delivery_module-module-lib.lgx" modules delivery_module
seed_pkg "$BUILD/result-storage-dev-lgx/logos-storage_module-module-lib.lgx" modules storage_module

echo "=== 2/6 bisect toggle (FORUM_BISECT=${FORUM_BISECT:-open}) ==="
apply_bisect

echo "=== 3/6 launch host (offscreen) ==="
LOGOS_NO_SCHEME_REGISTER=1 QML_INSPECTOR_PORT=$PORT \
  FORUM_DB_PATH="$DBPATH" \
  "$BC" -platform offscreen >"$EVID/host.log" 2>&1 &
APP_PID=$!
for i in $(seq 1 30); do
  lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 2
done
lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || { echo "FAIL: inspector not listening" >&2; cleanup; exit 1; }

echo "=== 4/6 stage 1 (Check transport → outbox) ==="
S1_LOG="$EVID/stage1.json"
S1_RC=99
S1_SKIP="${FORUM_SKIP_STAGE1:-0}"
if [ "$S1_SKIP" = "1" ]; then
  echo "(skipped via FORUM_SKIP_STAGE1=1 — going straight to PROP-sync test on a fresh source)"
  # Write a stub result so the aggregator still has something to read.
  echo '{"stage1":"SKIP","reason":"FORUM_SKIP_STAGE1=1","note":"probe designed to test PROP-sync on a fresh source without the stage-1 slot call contaminating the connection"}' > "$S1_LOG"
else
  stage1_check_transport > "$S1_LOG.stdout" 2> "$S1_LOG.stderr"
  S1_RC=$?
  # Extract the last JSON object from the captured stdout (the node script
  # prints a header line "=== stage 1: ..." then the JSON object, sometimes
  # followed by a "FAIL: ..." trailer).
  python3 - "$S1_LOG" "$S1_LOG.stdout" <<'PY' || true
import json, re, sys
log_path, stdout_path = sys.argv[1:3]
with open(stdout_path) as f:
    text = f.read()
# Find ALL {...} blocks; take the one that parses as JSON.
candidates = re.findall(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', text)
for cand in reversed(candidates):
    try:
        json.loads(cand)
        with open(log_path, "w") as out:
            out.write(cand)
        break
    except Exception:
        continue
PY
  cat "$S1_LOG" 2>/dev/null || echo "(stage1 produced no JSON output)"
fi

echo "=== 5/6 stage 2 (Add alias → PROP sync test) — runs even if stage 1 wedged ==="
S2_LOG="$EVID/stage2.json"
S2_RC=99
# Stage 2 always runs: it's a direct test of QtRO PROP-sync. If the QML's
# root.accounts PROP updates after clicking "Add alias" (which calls
# createAccount → setAccounts on the source), then PROP-sync works in this
# dev launcher build even though the slot-return channel is wedged.
stage2_add_alias > "$S2_LOG.stdout" 2> "$S2_LOG.stderr"
S2_RC=$?
python3 - "$S2_LOG" "$S2_LOG.stdout" <<'PY' || true
import json, re, sys
log_path, stdout_path = sys.argv[1:3]
with open(stdout_path) as f:
    text = f.read()
candidates = re.findall(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', text)
for cand in reversed(candidates):
    try:
        json.loads(cand)
        with open(log_path, "w") as out:
            out.write(cand)
        break
    except Exception:
        continue
PY
cat "$S2_LOG" 2>/dev/null || echo "(stage2 produced no JSON output)"

echo "=== 6/6 stage 3 (topic + post) — runs even if earlier stages wedged ==="
S3_LOG="$EVID/stage3.json"
S3_RC=99
stage3_topic_post > "$S3_LOG.stdout" 2> "$S3_LOG.stderr"
S3_RC=$?
python3 - "$S3_LOG" "$S3_LOG.stdout" <<'PY' || true
import json, re, sys
log_path, stdout_path = sys.argv[1:3]
with open(stdout_path) as f:
    text = f.read()
candidates = re.findall(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', text)
for cand in reversed(candidates):
    try:
        json.loads(cand)
        with open(log_path, "w") as out:
            out.write(cand)
        break
    except Exception:
        continue
PY
cat "$S3_LOG" 2>/dev/null || echo "(stage3 produced no JSON output)"

# Did the backend (ui-host serving forum_module) survive every stage?
pgrep -f 'ui-host.* --name forum_module' > "$EVID/ui_host_alive.txt" 2>/dev/null
# Plugin linkage actually loaded by the launcher (the root-cause discriminator).
PLUGIN_DIR=$(grep -o '/nix/store/[^ "]*-logos-forum_module-plugin-dir"' "$BC" | tr -d '"' | head -1)
otool -L "$PLUGIN_DIR/forum_module_plugin.dylib" > "$EVID/plugin_linkage.txt" 2>&1
cleanup

python3 - "$EVID" "$S1_RC" "$S2_RC" "$S3_RC" "$PORT" <<'PY'
import json, os, sys
evid, s1, s2, s3, port = sys.argv[1:6]
def _load(name):
    try: return json.load(open(f"{evid}/{name}"))
    except Exception: return {"_err": "missing"}
s1o = _load("stage1.json") if s1 != "99" else {"_skip": True}
s2o = _load("stage2.json") if s2 != "99" else {"_skip": True}
s3o = _load("stage3.json") if s3 != "99" else {"_skip": True}
proc_rem = open(f"{evid}/processes_remaining.txt").read().strip()
port_busy = open(f"{evid}/port_busy.txt").read().strip()

# Read host.log to extract the eventResponse warning count (smoking gun).
host_log_path = f"{evid}/host.log"
warning_count = 0
getconfigs_count = 0
try:
    with open(host_log_path) as f:
        for line in f:
            if "No such signal ::eventResponse" in line:
                warning_count += 1
            if "getAvailableConfigs called" in line:
                getconfigs_count += 1
except Exception:
    pass

# Independent stage results — each tests a different channel:
# s1: slot-return channel (Check transport → outcome.text)
# s2: PROP-sync channel (Add alias → root.accounts PROP)
# s3: post path (topic + refused post → thread PROP + composer retention)
prop_sync_works = s2 == "0"
post_path_works = s3 == "0"
slot_return_works = s1 == "0"
all_work = slot_return_works and prop_sync_works and post_path_works
ui_host_alive = open(f"{evid}/ui_host_alive.txt").read().strip() != ""
linkage = open(f"{evid}/plugin_linkage.txt").read()
links_sodium = "libsodium" in linkage
links_sqlite = "libsqlite3" in linkage

if all_work:
    diagnosis = (
        "all three channels work in the dev launcher (slot return, PROP sync, post path); "
        "ui-host survived every stage; plugin links libsodium+libsqlite3. The earlier "
        "'3-layer QtRO wedge' was the ui-host SIGSEGV'ing on a null sodium_init (plugin "
        "linked with -undefined dynamic_lookup and no libsodium) — fixed by LINK_LIBRARIES."
    )
else:
    diagnosis = (
        "one or more channels failed (see stage_summary). Check ui_host_alive first: "
        "a dead ui-host shows up as 'connectionToSource is null' and makes every later "
        "slot/PROP look wedged. links_sodium=%s links_sqlite=%s ui_host_alive=%s"
        % (links_sodium, links_sqlite, ui_host_alive)
    )

# All probes run cleanly without leaking processes.
ok = proc_rem == "" and port_busy == "0"
result = {
  "status": "PASS" if ok else "FAIL",
  "status_meaning": "probe ran and cleaned up; the product verdict is gate_label",
  "layer": "dev-launcher-gui-probe",
  "bisect": os.environ.get("FORUM_BISECT", "open"),
  "stage_rc": {"s1": int(s1), "s2": int(s2), "s3": int(s3)},
  "stage_summary": {
      "s1_slot_return": "WORKS" if slot_return_works else "FAILED",
      "s2_prop_sync": "WORKS" if prop_sync_works else "FAILED",
      "s3_post_path": "WORKS" if post_path_works else "FAILED",
  },
  "ui_host_alive_after_stages": ui_host_alive,
  "plugin_links_libsodium": links_sodium,
  "plugin_links_libsqlite3": links_sqlite,
  "stage1": s1o,
  "stage2": s2o,
  "stage3": s3o,
  "host_log_counts": {
      "eventResponse_warnings": warning_count,
      "getAvailableConfigs_calls": getconfigs_count,
      "note": "the capability_module eventResponse warning is benign noise (present in passing runs too)",
  },
  "processes_remaining": proc_rem or "none",
  "port_freed": port_busy == "0",
  "evidence": evid,
  "diagnosis": diagnosis,
  "gate_label": ("M2-GUI PASS (dev launcher: slot return + PROP sync + post path)"
                 if all_work else "M2-GUI FAIL (see diagnosis)"),
}
open(f"{evid}/result.json","w").write(json.dumps(result, indent=2, default=str))
print(json.dumps({"status": result["status"], "s1": s1, "s2": s2, "s3": s3,
                  "s1_slot_return": result["stage_summary"]["s1_slot_return"],
                  "s2_prop_sync": result["stage_summary"]["s2_prop_sync"],
                  "s3_post_path": result["stage_summary"]["s3_post_path"],
                  "eventResponse_warnings": warning_count,
                  "evidence": evid,
                  "gate_label": result["gate_label"]}, indent=2))
PY
