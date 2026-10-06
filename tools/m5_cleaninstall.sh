#!/usr/bin/env bash
# LP-0026 Forum — M5 clean-install proof (repeatable, isolated, both flavors).
#
# 1. Builds the .lgx FRESH (dev variant — required by nix-dev hosts).
# 2. Creates a FRESH isolated Basecamp profile (nothing carried over).
# 3. Seeds the profile from the freshly built .lgx payload (the exact layout
#    an install produces — same scanner contract the lgpm path uses).
# 4. Launches the inspector-enabled Basecamp host on an isolated --user-dir.
# 5. Drives the real UI via the Qt Inspector: finds the Forum app tile,
#    activates it, asserts the module view renders honestly.
# 6. Proves cleanup (all owned processes gone, ports free).
#
# Usage: bash tools/m5_cleaninstall.sh
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$HOME/.local/share/lp0026-forum-dev"
EV="$REPO_ROOT/evidence/m5-package"
STAMP="$(date +%Y%m%d-%H%M%S)"
EVID="$EV/cleaninstall-$STAMP"
BC="$STATE/builds/result-basecamp/bin/LogosBasecamp"
PROFILE="$STATE/basecamp-profiles/m5-cleaninstall"
PORT=3771
mkdir -p "$EVID"

fail() { echo "FAIL: $1"; echo "{\"status\":\"FAIL\",\"reason\":\"$1\",\"evidence\":\"$EVID\"}" > "$EVID/result.json"; exit 1; }

echo "=== 1/5 fresh .lgx build"
nix build "path:$REPO_ROOT#lgx" --max-jobs 2 --cores 4 --accept-flake-config \
    -o "$REPO_ROOT/result-lgx-dev" >"$EVID/build-lgx.log" 2>&1 \
    || fail "lgx build failed"
LGX="$REPO_ROOT/result-lgx-dev/logos-forum_module-module.lgx"
[ -f "$LGX" ] || fail "lgx missing"
LGX_SHA=$(shasum -a 256 "$LGX" | cut -d' ' -f1)
tar -xzOf "$LGX" manifest.json > "$EVID/manifest.json"
echo "lgx sha256: $LGX_SHA"

echo "=== 2/5 fresh isolated profile"
rm -rf "$PROFILE"
mkdir -p "$PROFILE/plugins/forum_module"

echo "=== 3/5 seed install layout (module + its declared dependencies)"
seed_pkg() { # lgx bucket name
  local LGXF="$1" BUCKET="$2" NAME="$3"
  [ -f "$LGXF" ] || fail "dependency package missing: $LGXF"
  local TMP; TMP=$(mktemp -d)
  tar -xzf "$LGXF" -C "$TMP"
  local V; V=$(python3 -c "import json;print(list(json.load(open('$TMP/manifest.json'))['main'])[0])")
  mkdir -p "$PROFILE/$BUCKET/$NAME"
  cp -R "$TMP/variants/$V/." "$PROFILE/$BUCKET/$NAME/"
  cp "$TMP/manifest.json" "$PROFILE/$BUCKET/$NAME/"
  if [ -d "$TMP/assets" ]; then
    mkdir -p "$PROFILE/$BUCKET/$NAME/assets"
    cp -R "$TMP/assets/." "$PROFILE/$BUCKET/$NAME/assets/"
  fi
  echo "$V" > "$PROFILE/$BUCKET/$NAME/variant"
  rm -rf "$TMP"
  echo "seeded $NAME ($BUCKET, $V)"
}
BUILD="$STATE/builds"
seed_pkg "$LGX" plugins forum_module
# Declared dependencies — a real install carries them; the nix-dev host
# needs the -dev variants (built from the pinned flakes, store-verified).
[ -f "$BUILD/result-delivery-dev-lgx/logos-delivery_module-module-lib.lgx" ] \
  || nix build github:logos-co/logos-delivery-module/v0.3.0#lgx \
       --max-jobs 2 --cores 4 --accept-flake-config \
       -o "$BUILD/result-delivery-dev-lgx" >>"$EVID/build-lgx.log" 2>&1
[ -f "$BUILD/result-storage-dev-lgx/logos-storage_module-module-lib.lgx" ] \
  || nix build github:logos-co/logos-storage-module/v3.0.0#lgx \
       --max-jobs 2 --cores 4 --accept-flake-config \
       -o "$BUILD/result-storage-dev-lgx" >>"$EVID/build-lgx.log" 2>&1
seed_pkg "$BUILD/result-delivery-dev-lgx/logos-delivery_module-module-lib.lgx" modules delivery_module
seed_pkg "$BUILD/result-storage-dev-lgx/logos-storage_module-module-lib.lgx" modules storage_module
find "$PROFILE" -type f | sort > "$EVID/profile-files.txt"
VARIANT=$(cat "$PROFILE/plugins/forum_module/variant")

echo "=== 4/5 launch isolated Basecamp host (inspector :$PORT)"
[ -x "$BC" ] || fail "inspector Basecamp missing (build it first)"
LOGOS_NO_SCHEME_REGISTER=1 QML_INSPECTOR_PORT=$PORT \
  "$BC" --user-dir "$PROFILE" >"$EVID/basecamp.log" 2>&1 &
APP_PID=$!
for i in $(seq 1 30); do
  lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 2
done
lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || fail "inspector not listening"

echo "=== 5/5 drive the real UI (tile → module view → honest states)"
# A failed drive must still reach the cleanup proof below (verdict uses ui-drive.json).
node - "$PORT" >"$EVID/ui-drive.json" <<'EOF' || echo "UI drive reported failure (verdict below)"
import net from "node:net";
const port = parseInt(process.argv[2], 10);
class C {
  constructor(p){this.port=p;this.id=0;this.pending=new Map();this.buffer="";}
  connect(){return new Promise((res,rej)=>{const s=net.createConnection({host:"localhost",port:this.port});s.once("connect",()=>{this.socket=s;res();});s.once("error",e=>rej(new Error(e.message)));s.on("data",c=>{this.buffer+=c.toString();let i;while((i=this.buffer.indexOf("\n"))>=0){const l=this.buffer.slice(0,i).trim();this.buffer=this.buffer.slice(i+1);if(!l)continue;try{const m=JSON.parse(l);const p=this.pending.get(String(m.id));if(p){this.pending.delete(String(m.id));p.resolve(m);}}catch{}}});});}
  send(command,params={}){const id=++this.id;return new Promise((res,rej)=>{const t=setTimeout(()=>{this.pending.delete(String(id));rej(new Error("timeout "+command));},20000);this.pending.set(String(id),{resolve:res,timer:t});this.socket.write(JSON.stringify({id,command,params})+"\n");});}
}
const c=new C(port); await c.connect();
const out = {};
const tile = await c.send("findAndClick", {text:"Forum"});
out.tile_clicked = tile.ok === true;
for (let k=0;k<45;k++){
  const r = await c.send("findByProperty",{property:"text",value:"Logos Forum"}).catch(()=>({count:0}));
  if (r.count > 0) { out.module_view = true; break; }
  await new Promise(x=>setTimeout(x,1000));
}
// Transport diagnostics sit behind "Network details".
out.details_opened = (await c.send("findAndClick",{text:"Network details",exact:true}).catch(()=>({ok:false}))).ok === true;
await new Promise(x=>setTimeout(x,500));
for (const t of ["Module ready","Backend status: Ready","Transport: no transport configured — posting unavailable (Required policy)"]) {
  const r = await c.send("findByProperty",{property:"text",value:t}).catch(()=>({count:0}));
  out[t] = r.count > 0;
}
// Store-backed flow through the REAL host (property/click only — Basecamp's
// inspector context has no evaluate globals): create an alias, then post
// while offline → saved and waiting ([pending] row), composer cleared.
const waitText = async (t, secs=15) => {
  for (let k=0;k<secs*2;k++){
    const r = await c.send("findByProperty",{property:"text",value:t}).catch(()=>({count:0}));
    if (r.count > 0) return true;
    await new Promise(x=>setTimeout(x,500));
  }
  return false;
};
const setByPlaceholder = async (ph, v) => {
  const f = await c.send("findByProperty",{property:"placeholderText",value:ph});
  if (!f.matches || !f.matches.length) return false;
  const r = await c.send("setProperty",{objectId:f.matches[0].id,property:"text",value:v});
  return !r.error;
};
out.alias_text_set = await setByPlaceholder("new alias", "m5-alice");
out.alias_click = (await c.send("findAndClick",{text:"Add alias"})).matchedText || null;
out.alias_created = await waitText("Alias created");
// Rows/hint carry the key id (unknown in advance) — read them by objectName.
const textsOf = async (name) => {
  const f = await c.send("findByProperty",{property:"objectName",value:name}).catch(()=>({matches:[]}));
  const out = [];
  for (const m of (f.matches||[])) {
    const p = await c.send("getProperties",{objectId:m.id}).catch(()=>({properties:[]}));
    const t = (p.properties||[]).find(x => x.name === "text");
    if (t) out.push(String(t.value));
  }
  return out;
};
const waitTextOf = async (name, pred, secs=15) => {
  for (let k=0;k<secs*2;k++){
    const hit = (await textsOf(name)).find(pred);
    if (hit) return hit;
    await new Promise(x=>setTimeout(x,500));
  }
  return null;
};
out.identity_hint = await waitTextOf("identityHint", t => /^Identity: m5-alice · id [0-9a-f]{16} /.test(t));
out.identity_shown = out.identity_hint !== null;
const POST = "TECHNICAL TEST DATA: m5 clean-install post";
out.post_text_set = await setByPlaceholder("Write a post (plain text)", POST);
out.send_click = (await c.send("findAndClick",{text:"Send"})).matchedText || null;
out.saved_shown = await waitText("Saved — it will be sent through Mix as soon as you are connected.");
out.pending_row = await waitTextOf("threadRow", t => /^m5-alice · id [0-9a-f]{16} \[pending\]: /.test(t) && t.endsWith(POST));
out.pending_row_shown = out.pending_row !== null;
const comp = await c.send("findByProperty",{property:"placeholderText",value:"Write a post (plain text)"});
const props = comp.matches && comp.matches.length
  ? await c.send("getProperties",{objectId:comp.matches[0].id}) : {properties:[]};
out.composer_cleared = (props.properties||[]).some(p => p.name === "text" && p.value === "");
console.log(JSON.stringify(out));
const storeFlow = out.alias_created && out.identity_shown && out.saved_shown
  && out.pending_row_shown && out.composer_cleared;
process.exit(out.tile_clicked && out.module_view && storeFlow ? 0 : 1);
EOF
cat "$EVID/ui-drive.json"
# Where did the backend put its store? (any forum.db the ui-host holds open)
UIH=$(pgrep -f "ui-host.*--name forum_module" | head -1)
[ -n "$UIH" ] && lsof -p "$UIH" 2>/dev/null | grep -E "forum\.db" | awk '{print $NF}' | sort -u > "$EVID/store-path.txt"

echo "=== 6/5 cleanup proof"
kill $APP_PID 2>/dev/null; sleep 3
kill -9 $APP_PID 2>/dev/null
sleep 1
LEFT=$(pgrep -f "$PROFILE" | head -3)
[ -z "$LEFT" ] || kill -9 $LEFT 2>/dev/null
sleep 1
REMAIN=$(pgrep -f "$PROFILE" | head -2)
PORT_BUSY=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | wc -l | tr -d ' ')

python3 - "$EVID" "$LGX_SHA" "$VARIANT" "$REMAIN" "$PORT_BUSY" <<'EOF' 
import json, sys
evid, sha, variant, remain, port_busy = sys.argv[1:6]
ui = json.load(open(f"{evid}/ui-drive.json"))
store_flow = all(ui.get(k) is True for k in (
    "alias_created", "identity_shown", "saved_shown", "pending_row_shown", "composer_cleared"))
ok = (ui.get("tile_clicked") and ui.get("module_view")
      and ui.get("Backend status: Ready") is True and store_flow
      and remain.strip() == "" and port_busy == "0")
result = {
    "status": "PASS" if ok else "FAIL",
    "layer": "m5-clean-install",
    "lgx_sha256": sha, "variant": variant,
    "fresh_profile": True, "isolated_user_dir": True,
    "ui_drive": ui,
    "store_flow_in_real_host": store_flow,
    "processes_remaining": remain.strip() or "none",
    "port_freed": port_busy == "0",
    "evidence": evid,
}
open(f"{evid}/result.json","w").write(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
sys.exit(0 if ok else 1)
EOF
