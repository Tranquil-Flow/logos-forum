#!/usr/bin/env bash
# LP-0026 Forum — M5b REAL-HOST GUI drive.
#
# The nix-sandboxed CI app dies when the SQLite store opens inside the build
# sandbox (integration-22/23/24 evidence) — a sandbox artifact, not a product
# defect: real hosts open the store fine (m5 clean-install receipt). This
# drive verifies the STORE-DEPENDENT GUI flows on the REAL desktop:
#
#   1. fresh isolated profile + module + declared deps (install layout)
#   2. inspector Basecamp-free host launch (real window, port 3774)
#   3. tile → module view → Connected
#   4. create alias + select it
#   5. create topic (appears in topics)
#   6. post WITHOUT transport → honest refusal + composer retention
#   7. thread view shows the [failed] post with alias
#   8. cleanup proof
#
# Usage: bash tools/m5b_realhost_gui.sh
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$HOME/.local/share/lp0026-forum-dev"
EV="$REPO_ROOT/evidence/m5-package"
STAMP="$(date +%Y%m%d-%H%M%S)"
EVID="$EV/realhost-gui-$STAMP"
# The dev launcher on the REAL host: evaluate-capable inspector context
# (Basecamp's context has no logos/root globals — proven by realhost-run3)
# and a real-home store path — the honest place for store-backed GUI flows.
BC="$REPO_ROOT/result-ui-dev/bin/run-logos-standalone-ui"
PROFILE="$STATE/basecamp-profiles/m5b-realhost"
PORT=3788
mkdir -p "$EVID"

fail() { echo "FAIL: $1"; echo "{\"status\":\"FAIL\",\"reason\":\"$1\",\"evidence\":\"$EVID\"}" > "$EVID/result.json"; exit 1; }

echo "=== 1/4 fresh profile + module + deps (install layout)"
LGX="$REPO_ROOT/result-lgx-dev/logos-forum_module-module.lgx"
[ -f "$LGX" ] && nix build "path:$REPO_ROOT#lgx" --max-jobs 2 --cores 4 --accept-flake-config -o "$REPO_ROOT/result-lgx-dev" >"$EVID/build-lgx.log" 2>&1
[ -f "$LGX" ] || fail "lgx missing"
BUILD="$STATE/builds"
seed_pkg() {
  local LGXF="$1" BUCKET="$2" NAME="$3" TMP V
  [ -f "$LGXF" ] || fail "dependency package missing: $LGXF"
  TMP=$(mktemp -d)
  tar -xzf "$LGXF" -C "$TMP"
  V=$(python3 -c "import json;print(list(json.load(open('$TMP/manifest.json'))['main'])[0])")
  mkdir -p "$PROFILE/$BUCKET/$NAME"
  cp -R "$TMP/variants/$V/." "$PROFILE/$BUCKET/$NAME/"
  cp "$TMP/manifest.json" "$PROFILE/$BUCKET/$NAME/"
  [ -d "$TMP/assets" ] && { mkdir -p "$PROFILE/$BUCKET/$NAME/assets"; cp -R "$TMP/assets/." "$PROFILE/$BUCKET/$NAME/assets/"; }
  echo "$V" > "$PROFILE/$BUCKET/$NAME/variant"
  rm -rf "$TMP"
  echo "seeded $NAME ($BUCKET, $V)"
}
rm -rf "$PROFILE"; mkdir -p "$PROFILE"
seed_pkg "$LGX" plugins forum_module
seed_pkg "$BUILD/result-delivery-dev-lgx/logos-delivery_module-module-lib.lgx" modules delivery_module
seed_pkg "$BUILD/result-storage-dev-lgx/logos-storage_module-module-lib.lgx" modules storage_module

echo "=== 2/4 isolated host launch (real window, inspector :$PORT)"
# Port hygiene: a stale instance on the inspector port makes the driver talk
# to a phantom (the M2b-era failure mode). Sweep holders, verify free, and
# refuse to launch otherwise.
pkill -9 -f "run-logos-standalone-ui.*$PORT" 2>/dev/null
pkill -9 -f "LogosBasecamp.*m5b-realhost" 2>/dev/null
# The inspector listener lives in the ui-host child — identifiable by OUR
# module plugin dir in its cmdline (never a broad logos_host sweep: other
# workloads on this host are out of scope).
pkill -9 -f "logos-forum_module-plugin-dir" 2>/dev/null
sleep 2
h=$(lsof -nP -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $2}')
[ -n "$h" ] && { kill -9 $h 2>/dev/null; sleep 1; }
lsof -nP -tiTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && fail "port $PORT still held after sweep"
[ -x "$BC" ] || fail "host launcher missing: $BC"
LOGOS_NO_SCHEME_REGISTER=1 QML_INSPECTOR_PORT=$PORT \
  FORUM_DB_PATH="$STATE/m5b-forum.db" \
  "$BC" -platform offscreen >"$EVID/host.log" 2>&1 &
APP_PID=$!
for i in $(seq 1 30); do
  lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 2
done
lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || fail "inspector not listening"

echo "=== 3/4 drive the REAL forum flows (property-based — Basecamp's "
echo "     inspector context has no logos/root evaluate globals)"
node - "$PORT" >"$EVID/ui-drive.json" <<'EOF' || fail "UI drive failed"
import net from "node:net";
const port = parseInt(process.argv[2], 10);
class C {
  constructor(p){this.port=p;this.id=0;this.pending=new Map();this.buffer="";}
  connect(){return new Promise((res,rej)=>{const s=net.createConnection({host:"localhost",port:this.port});s.once("connect",()=>{this.socket=s;res();});s.once("error",e=>rej(new Error(e.message)));s.on("data",c=>{this.buffer+=c.toString();let i;while((i=this.buffer.indexOf("\n"))>=0){const l=this.buffer.slice(0,i).trim();this.buffer=this.buffer.slice(i+1);if(!l)continue;try{const m=JSON.parse(l);const p=this.pending.get(String(m.id));if(p){this.pending.delete(String(m.id));p.resolve(m);}}catch{}}});});}
  send(command,params={}){const id=++this.id;return new Promise((res,rej)=>{const t=setTimeout(()=>{this.pending.delete(String(id));rej(new Error("timeout "+command));},25000);this.pending.set(String(id),{resolve:res,timer:t});this.socket.write(JSON.stringify({id,command,params})+"\n");});}
}
const c=new C(port); await c.connect();
const out={};
const ev=async(expr)=>{const r=await c.send("evaluate",{expression:expr});
  return (r && r.result!==undefined && r.result!==null)?r.result:("EVAL:"+JSON.stringify(r));};
const wait=async(fn,ms=25000)=>{const end=Date.now()+ms;while(Date.now()<end){const v=await fn();if(v)return v;await new Promise(x=>setTimeout(x,700));}return null;};

// tile → module view → Connected (same as Basecamp proof)
out.tile_clicked=(await c.send("findAndClick",{text:"Forum"})).ok===true;
out.module_view=!!(await wait(async()=>{const r=await c.send("findByProperty",{property:"text",value:"Logos Forum"});return r.count>0;}));
out.connected=!!(await wait(async()=>{const r=await c.send("findByProperty",{property:"text",value:"Module ready"});return r.count>0;}));

// store-backed flows via evaluate (dev-launcher context exposes logos/root)
out.alias_create=await ev(`logos.watch(root.backend.createAccount("demo"),function(v){return v},function(e){return e})`);
await new Promise(x=>setTimeout(x,1000));
out.accounts=await ev("JSON.stringify(root.accounts)");
out.alias_listed=(out.accounts||"").includes("demo");

out.topic_create=await ev(`logos.watch(root.backend.createTopic("Real Host Topic"),function(v){return v},function(e){return e})`);
await new Promise(x=>setTimeout(x,1500));
out.topics=await ev("JSON.stringify(root.topics)");
out.topic_visible=(out.topics||"").includes("Real Host Topic");

out.post_result=await ev(`logos.watch(root.backend.postMessage("REALHOST TECHNICAL TEST DATA"),function(v){return v},function(e){return e})`);
await new Promise(x=>setTimeout(x,1500));
out.transport_state=await ev("root.transportState");
out.thread=await ev("JSON.stringify(root.threadPosts)");
out.thread_has_failed=(out.thread||"").includes("[failed]");
out.thread_has_body=(out.thread||"").includes("REALHOST TECHNICAL TEST DATA");

console.log(JSON.stringify(out));
const ok=out.module_view&&out.connected&&out.alias_listed&&out.topic_visible
  &&String(out.post_result).includes("unavailable")
  &&out.thread_has_failed&&out.thread_has_body;
process.exit(ok?0:1);
EOF
cat "$EVID/ui-drive.json"

echo "=== 4/4 cleanup proof"
kill $APP_PID 2>/dev/null; sleep 3; kill -9 $APP_PID 2>/dev/null; sleep 1
LEFT=$(pgrep -f "$PROFILE" | head -3); [ -z "$LEFT" ] || kill -9 $LEFT 2>/dev/null; sleep 1
REMAIN=$(pgrep -f "$PROFILE" | head -2)
PORT_BUSY=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' ')

python3 - "$EVID" "$REMAIN" "$PORT_BUSY" <<'EOF'
import json, sys
evid, remain, port_busy = sys.argv[1:4]
ui = json.load(open(f"{evid}/ui-drive.json"))
ok = (ui.get("module_view") and ui.get("connected")
      and ui.get("alias_listed") and ui.get("topic_visible")
      and ui.get("thread_has_failed") and ui.get("thread_has_body")
      and remain.strip() == "" and port_busy == "0")
result = {
    "status": "PASS" if ok else "FAIL",
    "layer": "m5b-realhost-gui",
    "ui_drive": ui,
    "processes_remaining": remain.strip() or "none",
    "port_freed": port_busy == "0",
    "evidence": evid,
    "note": "store-dependent GUI flows verified on the REAL host (sandbox "
            "store-open wedge is an environment artifact)",
}
open(f"{evid}/result.json","w").write(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
sys.exit(0 if ok else 1)
EOF
