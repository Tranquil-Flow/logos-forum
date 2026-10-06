#!/usr/bin/env bash
# Forum in the RELEASE Basecamp app on Windows (CI: windows-latest, Git Bash).
#
# Unpacks the official Basecamp 0.3.1 Windows installer (sha256-pinned), seeds
# a fresh --user-dir with the Forum package and the official delivery_module
# 0.3.0 / storage_module 3.0.0 packages the way Package Manager lays them out,
# opens Forum with --uri and waits for its store to open on its own
# (module_data/forum_module/forum.db) — the same check as
# evidence/m5-package/release-app-20261004 on macOS. Then it drives the
# window like a user (clicks + keystrokes at the coordinates of the runner's
# 1024x768 desktop): writes a labelled test post while offline (kept,
# waiting), connects to logos.dev and checks the store marks the post sent —
# a send that only succeeds through Mix. Screenshots and logs go to $OUT.
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
DELIVERY_SHA=f744f0f9ef84438b6da3985561cb8d2eedf36c9340d29d839353cf8d728aa088
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
fetch "$BASE/delivery_module-v0.3.0/delivery_module-0.3.0.lgx" "$DELIVERY_SHA" "$WORK/delivery.lgx"
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

LOGOS_NO_SCHEME_REGISTER=1 "$BIN" --user-dir "$(cygpath -w "$PROFILE")" \
  --uri=basecamp://app/forum_module > "$OUT/basecamp-stdout.log" 2>&1 &
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
    [W.U]::SetCursorPos($1, $2); Start-Sleep -Milliseconds 200
    [W.U]::mouse_event(2,0,0,0,0); [W.U]::mouse_event(4,0,0,0,0)"
  sleep 1
}
type_text() {
  powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('$1')"
  sleep 1
}
post_state() { # state of the newest post, read from the profile's store
  python -c "
import sqlite3,sys
c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
r=c.execute(\"select state,privacy from posts where type='post' order by rowid desc limit 1\").fetchone()
print(' '.join(r) if r else 'none')" "$(cygpath -w "$DB")" 2>/dev/null || echo "unreadable"
}

sent=0
if [ "$ok" = 1 ]; then
  sleep 5 # let the window finish drawing
  shot 1-opened
  # Write a post while offline: it must be kept on the device, waiting.
  click 572 592
  type_text "TEST POST - automated Windows check, CI run ${GITHUB_RUN_ID:-local} - test data, please ignore"
  type_text "^{ENTER}"   # Ctrl+Enter: the composer's send shortcut
  sleep 2
  echo "after Send, offline: $(post_state)" | tee -a "$OUT/result.txt"
  shot 2-written-offline
  # Connect; the waiting post must go out through Mix.
  click 925 108
  for i in $(seq 1 240); do
    st=$(post_state)
    case "$st" in sent*) sent=1; echo "post $st after connecting ${i}s" | tee -a "$OUT/result.txt"; break ;; esac
    sleep 1
  done
  [ "$sent" = 1 ] || echo "post not sent within 240 s of connecting: $(post_state)" | tee -a "$OUT/result.txt"
  sleep 3
  shot 3-connected
fi
tasklist //FI "IMAGENAME eq LogosBasecamp.exe" > "$OUT/processes.txt" || true
tasklist //FI "IMAGENAME eq logos_host.exe" >> "$OUT/processes.txt" || true
tasklist //FI "IMAGENAME eq ui-host.exe" >> "$OUT/processes.txt" || true
taskkill //F //T //IM LogosBasecamp.exe >/dev/null 2>&1 || true
taskkill //F //IM ui-host.exe >/dev/null 2>&1 || true
taskkill //F //IM logos_host.exe >/dev/null 2>&1 || true
sleep 3

(cd "$PROFILE" && find . -path ./plugins -prune -o -path ./modules -prune -o -print | sort) > "$OUT/tree.txt"
(cd "$PROFILE" && find plugins/forum_module | sort) > "$OUT/forum-plugin-files.txt"
find "$PROFILE" -name "*.log" -not -path "*/plugins/*" -not -path "*/modules/*" \
  -exec cp {} "$OUT/" \; 2>/dev/null || true
grep -hiE "forum_module" "$OUT"/*.log | head -40 > "$OUT/forum-log-lines.txt" || true
[ "$ok" = 1 ] || { echo "FAIL: no forum.db after 120 s" | tee -a "$OUT/result.txt"; exit 1; }
echo "PASS: Forum loaded in Basecamp 0.3.1 on Windows and opened its store"
[ "$sent" = 1 ] || { echo "FAIL: the post was not sent through Mix"; exit 1; }
echo "PASS: a post written offline was sent through Mix after connecting"
