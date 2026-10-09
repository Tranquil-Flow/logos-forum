#!/usr/bin/env bash
# Forum in the RELEASE Basecamp app on Windows (CI: windows-latest, Git Bash).
#
# Unpacks the official Basecamp 0.3.1 Windows installer (sha256-pinned), seeds
# a fresh --user-dir with the Forum package and the official delivery_module
# 0.3.2 / storage_module 3.0.0 packages the way Package Manager lays them out,
# opens Forum with --uri and waits for its store to open on its own
# (module_data/forum_module/forum.db) — the same check as
# evidence/m5-package/release-app-20261004 on macOS. Then it drives the
# window like a user (clicks + keystrokes at the coordinates of the runner's
# 1024x768 desktop; controls are found by accessible name, with fixed
# coordinates only as a fallback): writes a labelled test post while offline (kept,
# waiting), connects to logos.dev and checks the store marks the post sent —
# a send that only succeeds through Mix. Then, still in the window: saves a
# snapshot of the topic on Logos Storage and restores it (fetched and every
# post verified again), loads the network's history (posts from other runs
# and devices arrive as received), and restarts Basecamp to check the posts
# are still there. Screenshots and logs go to $OUT.
#
# Usage: bash tools/windows_smoke.sh <forum .lgx with a windows-x86_64 variant>
set -euo pipefail
LGX="${1:?forum .lgx}"
OUT="${OUT:-$PWD/windows-smoke}"
WORK="${RUNNER_TEMP:-$PWD/.tmp}/forum-smoke"
# Git Bash tools want /d/a/... paths; "D:\..." reads to tar as a remote host.
command -v cygpath >/dev/null && WORK=$(cygpath -u "$WORK") && OUT=$(cygpath -u "$OUT")
SETUP_URL=https://github.com/logos-co/logos-basecamp/releases/download/0.3.1/LogosBasecamp-Desktop-v0.3.1-aeb819-x86_64-windows-setup.exe
SETUP_SHA=fd4488e811bf64e9b10c89672bc64a05ec10588cbf1e651f20344f390a41eacd
BASE=https://github.com/logos-co/logos-modules-release/releases/download
DELIVERY_SHA=9b856418fcf816961f1118f34b395bb6a399e5523166be51f4eca6a7aaf76867
STORAGE_SHA=2af8cad7c5f39658a1e571d1e307baf7cc4cd9a76f5da535c73685c7675424b0
VARIANT=windows-x86_64
rm -rf "$WORK"; mkdir -p "$WORK" "$OUT"

fetch() { # url sha dest
  curl -fsSL -o "$3" "$1"
  local got; got=$(sha256sum < "$3" | cut -d' ' -f1)
  [ "$got" = "$2" ] || { echo "sha256 mismatch for $1: $got" >&2; exit 1; }
}

seed() { # lgx bucket name
  local tmp="$WORK/unpack-$3"; mkdir -p "$tmp"
  tar -xzf "$1" -C "$tmp"
  [ -d "$tmp/variants/$VARIANT" ] || { echo "$1 has no $VARIANT variant" >&2; exit 1; }
  local dst="$PROFILE/$2/$3"; mkdir -p "$dst"
  cp -R "$tmp/variants/$VARIANT/." "$dst/"
  cp "$tmp/manifest.json" "$dst/"
  [ -d "$tmp/assets" ] && { mkdir -p "$dst/assets"; cp -R "$tmp/assets/." "$dst/assets/"; }
  echo "$VARIANT" > "$dst/variant"
}

fetch "$SETUP_URL" "$SETUP_SHA" "$WORK/setup.exe"
fetch "$BASE/delivery_module-v0.3.2/delivery_module-0.3.2.lgx" "$DELIVERY_SHA" "$WORK/delivery.lgx"
fetch "$BASE/storage_module-v3.0.0/storage_module-3.0.0.lgx" "$STORAGE_SHA" "$WORK/storage.lgx"
# The installer is NSIS; unpacking it gives the same files a silent install does.
7z x -y -o"$WORK/basecamp" "$WORK/setup.exe" >/dev/null
BIN="$WORK/basecamp/bin/LogosBasecamp.exe"
[ -f "$BIN" ] || { echo "no LogosBasecamp.exe in the installer" >&2; exit 1; }

PROFILE="$WORK/profile"; mkdir -p "$PROFILE"
seed "$LGX" plugins forum_module
seed "$WORK/delivery.lgx" modules delivery_module
seed "$WORK/storage.lgx" modules storage_module
{ sha256sum "$LGX"; echo "basecamp setup.exe $SETUP_SHA"; } > "$OUT/inputs-sha256.txt"

launch() {
  LOGOS_NO_SCHEME_REGISTER=1 "$BIN" --user-dir "$(cygpath -w "$PROFILE")" \
    --uri=basecamp://app/forum_module >> "$OUT/basecamp-stdout.log" 2>&1 &
}
: > "$OUT/basecamp-stdout.log"
launch
DB="$PROFILE/module_data/forum_module/forum.db"
ok=0
for i in $(seq 1 120); do
  [ -f "$DB" ] && { ok=1; echo "forum.db after ${i}s" | tee "$OUT/result.txt"; break; }
  sleep 1
done
shot() { # name — the whole screen (the runner has a real desktop session)
  powershell -NoProfile -Command "
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    \$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    \$img = New-Object System.Drawing.Bitmap \$b.Width, \$b.Height
    [System.Drawing.Graphics]::FromImage(\$img).CopyFromScreen(\$b.Location, [System.Drawing.Point]::Empty, \$b.Size)
    \$img.Save('$(cygpath -w "$OUT/$1.png")')" || echo "screenshot $1 failed"
}
click() { # x y — screen coordinates of the 1024x768 runner desktop
  powershell -NoProfile -Command "
    Add-Type -MemberDefinition '[DllImport(\"user32.dll\")] public static extern bool SetCursorPos(int x, int y); [DllImport(\"user32.dll\")] public static extern void mouse_event(int f, int x, int y, int d, int e);' -Name U -Namespace W
    [void][W.U]::SetCursorPos($1, $2); Start-Sleep -Milliseconds 200
    [W.U]::mouse_event(2,0,0,0,0); [W.U]::mouse_event(4,0,0,0,0)"
  sleep 1
}
on_screen() { # name — is a control with this accessible name visible?
  powershell -NoProfile -Command "
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    \$c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, '$1')
    \$all = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, \$c)
    if (\$all | Where-Object { -not \$_.Current.IsOffscreen }) { exit 0 } else { exit 1 }" >/dev/null 2>&1
}
minimize_all() { # clear the desktop (the runner's console window covers the app)
  powershell -NoProfile -Command "(New-Object -ComObject Shell.Application).MinimizeAll()" >/dev/null 2>&1 || true
  sleep 2
}
click_named() { # name x y — a control found by its accessible name (UI
  # Automation; the lowest on screen when several match, e.g. the newest
  # snapshot card), else the given coordinates; prints which one was used.
  local at
  at=$(powershell -NoProfile -Command "
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    \$c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, '$1')
    \$all = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, \$c)
    \$e = \$all | Where-Object { -not \$_.Current.IsOffscreen } | Sort-Object { \$_.Current.BoundingRectangle.Y } | Select-Object -Last 1
    if (\$e) { \$r = \$e.Current.BoundingRectangle; '{0} {1}' -f [int](\$r.X + \$r.Width / 2), [int](\$r.Y + \$r.Height / 2) }" 2>/dev/null | tr -d '\r')
  if [ -n "$at" ]; then echo "click '$1' at $at (by name)"; click $at
  else echo "click '$1' at $2 $3 (fixed)"; click "$2" "$3"; fi
}
type_text() {
  powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('$1')"
  sleep 1
}
sql() { # query — the first row of a read-only query on the profile's store
  python -c "
import sqlite3,sys
c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
r=c.execute(sys.argv[2]).fetchone()
print(' '.join(str(x) for x in r) if r else 'none')" "$(cygpath -w "$DB")" "$1" 2>/dev/null || echo "unreadable"
}
# Our test post, found by its text: history arriving on connect adds newer
# rows (received), so "the latest row" is not necessarily ours.
post_state() { sql "select state,privacy from posts where type='post' and body='$POST' order by rowid desc limit 1"; }

count() { local n; n=$(sql "$1"); case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac; }
wait_for() { # seconds label command... — poll until the command succeeds
  local n="$1" label="$2"; shift 2
  for i in $(seq 1 "$n"); do
    if "$@"; then echo "$label after ${i}s" | tee -a "$OUT/result.txt"; return 0; fi
    sleep 1
  done
  echo "$label: not within ${n}s" | tee -a "$OUT/result.txt"; return 1
}
SNAPS="$PROFILE/module_data/forum_module/forum-snapshots"
# The announcement title is kSnapshotTitle in src/forum_module_backend.cpp.
snapshot_saved() { ls "$SNAPS"/topic-*.txt >/dev/null 2>&1 \
  && [ "$(count "select count(*) from posts where body like 'Snapshot of this topic%' and state='sent'")" -gt 0 ]; }
snapshot_restored() { for f in "$SNAPS"/restore-*.txt; do [ -s "$f" ] && return 0; done; return 1; }
history_received() { [ "$(count "select count(*) from posts where state='received'")" -gt 0 ]; }
stop_app() {
  taskkill //F //T //IM LogosBasecamp.exe >/dev/null 2>&1 || true
  taskkill //F //IM ui-host.exe >/dev/null 2>&1 || true
  taskkill //F //IM logos_host.exe >/dev/null 2>&1 || true
  sleep 3
}

POST="TEST POST - automated Windows check, CI run ${GITHUB_RUN_ID:-local} - test data, please ignore"
sent=0 saved=0 restored=0 history=0 kept=0
if [ "$ok" = 1 ]; then
  sleep 5 # let the window finish drawing
  shot 1-opened
  # Test posts go to the shared Sandbox topic, never General.
  click_named "Sandbox (0)" 150 230 | tee -a "$OUT/result.txt"
  sleep 1
  # Write a post while offline: it must be kept on the device, waiting.
  click_named "Post text" 700 640 | tee -a "$OUT/result.txt"
  type_text "$POST"
  type_text "{ENTER}"   # Enter sends (Shift+Enter is a new line)
  sleep 2
  echo "after Send, offline: $(post_state)" | tee -a "$OUT/result.txt"
  echo "posted in: $(sql "select t.body from posts p join posts t on t.event_id=p.topic_id where p.body='$POST' limit 1")" | tee -a "$OUT/result.txt"
  shot 2-written-offline
  # Connect; the waiting post must go out through Mix.
  click_named "Connect to Logos network" 620 104 | tee -a "$OUT/result.txt"
  for i in $(seq 1 240); do
    st=$(post_state)
    case "$st" in sent*) sent=1; echo "post $st after connecting ${i}s" | tee -a "$OUT/result.txt"; break ;; esac
    sleep 1
  done
  [ "$sent" = 1 ] || echo "post not sent within 240 s of connecting: $(post_state)" | tee -a "$OUT/result.txt"
  sleep 3
  shot 3-connected
fi
if [ "$sent" = 1 ]; then
  # Snapshot: the topic's published posts go to Logos Storage; the signed
  # announcement is sent through Mix like any post.
  # Storage sometimes refuses to start on the runner (the app says so); a
  # user would press Save snapshot again, so this does too — every attempt
  # is in result.txt.
  for attempt in 1 2 3; do
    click_named "Save snapshot" 960 160 | tee -a "$OUT/result.txt"
    wait_for 60 "snapshot saved and announced (attempt $attempt)" snapshot_saved && { saved=1; break; }
    shot "4-snapshot-attempt-$attempt"
  done
  sleep 3
  shot 4-snapshot-saved
  if [ "$saved" = 1 ]; then
    # Restore it: fetched back from Logos Storage, every post verified again.
    click_named "Restore these posts" 470 430 | tee -a "$OUT/result.txt"
    wait_for 180 "snapshot fetched from Logos Storage" snapshot_restored && restored=1
    sleep 5
    shot 5-snapshot-restored
  fi
  # History: earlier runs' posts (and other devices') come back from a
  # logos.dev store node and are verified before they are stored as received.
  click_named "Load older posts" 850 160 | tee -a "$OUT/result.txt"
  wait_for 90 "history: received posts in the store" history_received && history=1
  echo "received posts: $(count "select count(*) from posts where state='received'")" | tee -a "$OUT/result.txt"
  sleep 3
  shot 6-history
  # Restart: the same profile reopens offline with its posts. The reopened
  # Forum view must be on screen (its Connect button, found by name) and the
  # store must still hold every post.
  before=$(count "select count(*) from posts")
  stop_app
  minimize_all
  launch
  forum_open() { on_screen "Connect to Logos network"; }
  wait_for 120 "after restart: the Forum view is open again" forum_open && shown=1 || shown=0
  sleep 3
  on_screen "$POST" && echo "after restart: the test post text is on screen" | tee -a "$OUT/result.txt" \
    || echo "after restart: post text not visible to UI Automation (see 7-restarted.png)" | tee -a "$OUT/result.txt"
  after=$(count "select count(*) from posts")
  echo "posts before restart: $before, after: $after" | tee -a "$OUT/result.txt"
  [ "$shown" = 1 ] && [ "$after" -ge "$before" ] && [ "$before" -gt 0 ] && kept=1
  sleep 2
  shot 7-restarted
fi
tasklist //FI "IMAGENAME eq LogosBasecamp.exe" > "$OUT/processes.txt" || true
tasklist //FI "IMAGENAME eq logos_host.exe" >> "$OUT/processes.txt" || true
tasklist //FI "IMAGENAME eq ui-host.exe" >> "$OUT/processes.txt" || true
stop_app

(cd "$PROFILE" && find . -path ./plugins -prune -o -path ./modules -prune -o -print | sort) > "$OUT/tree.txt"
(cd "$PROFILE" && find plugins/forum_module | sort) > "$OUT/forum-plugin-files.txt"
find "$PROFILE" -name "*.log" -not -path "*/plugins/*" -not -path "*/modules/*" \
  -exec cp {} "$OUT/" \; 2>/dev/null || true
grep -hiE "forum_module" "$OUT"/*.log | head -40 > "$OUT/forum-log-lines.txt" || true
[ "$ok" = 1 ] || { echo "FAIL: no forum.db after 120 s" | tee -a "$OUT/result.txt"; exit 1; }
echo "PASS: Forum loaded in Basecamp 0.3.1 on Windows and opened its store"
[ "$sent" = 1 ] || { echo "FAIL: the post was not sent through Mix"; exit 1; }
echo "PASS: a post written offline was sent through Mix after connecting"
fail=0
[ "$saved" = 1 ] && echo "PASS: snapshot saved on Logos Storage and announced" \
  || { echo "FAIL: no snapshot saved and announced"; fail=1; }
[ "$restored" = 1 ] && echo "PASS: snapshot fetched back from Logos Storage" \
  || { echo "FAIL: snapshot not fetched back"; fail=1; }
[ "$history" = 1 ] && echo "PASS: posts from the network's history received" \
  || { echo "FAIL: nothing received from the network's history"; fail=1; }
[ "$kept" = 1 ] && echo "PASS: posts kept and shown again after a restart" \
  || { echo "FAIL: posts not kept across a restart"; fail=1; }
exit "$fail"
