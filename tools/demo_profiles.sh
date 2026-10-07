#!/usr/bin/env bash
# Fresh Basecamp profiles with Forum installed, in the RELEASE Basecamp app —
# what an evaluator runs. Used to record the demo and for cross-machine tests.
#
# Each profile gets the release-variant Forum package (#lgx-portable) and
# the official delivery_module 0.3.2 / storage_module 3.0.0 packages
# (sha256-pinned in docs/PINS.json), laid out exactly as Package Manager
# installs them. Nothing else is carried over.
#
# Usage:
#   bash tools/demo_profiles.sh setup A B     # (re)create profiles A and B
#   bash tools/demo_profiles.sh launch A      # start the release app on A
#   bash tools/demo_profiles.sh stop          # quit every app this started
#   bash tools/demo_profiles.sh app           # unpack the pinned Basecamp 0.3.1
# Env: DEMO_ROOT (default ~/lp0026-demo), BASECAMP_APP (default: the pinned
# 0.3.1 app unpacked under DEMO_ROOT), FORUM_LGX (default: build #lgx-portable).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_ROOT="${DEMO_ROOT:-$HOME/lp0026-demo}"
APP="${BASECAMP_APP:-$DEMO_ROOT/LogosBasecamp-0.3.1.app}"
BIN="$APP/Contents/MacOS/LogosBasecamp"
DL="${FORUM_DOWNLOADS:-$HOME/.local/share/lp0026-forum-dev/downloads}"
BASE=https://github.com/logos-co/logos-modules-release/releases/download
DELIVERY_SHA=9b856418fcf816961f1118f34b395bb6a399e5523166be51f4eca6a7aaf76867
STORAGE_SHA=2af8cad7c5f39658a1e571d1e307baf7cc4cd9a76f5da535c73685c7675424b0
DMG_SHA=115102ed5bd17faa62d0a7f21faa73cd510c7610a9d344b2f81e1090f686c565
DMG_URL=https://github.com/logos-co/logos-basecamp/releases/download/0.3.1/LogosBasecamp-Desktop-v0.3.1-aeb819-aarch64.dmg
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) VARIANT=darwin-arm64 ;;
  Linux-x86_64) VARIANT=linux-amd64 ;;
  Linux-aarch64) VARIANT=linux-arm64 ;;
  *) echo "unsupported platform $(uname -s)-$(uname -m)" >&2; exit 2 ;;
esac

fetch_dep() { # name version sha
  local f="$DL/$1-$2.lgx"
  mkdir -p "$DL"
  [ -f "$f" ] || curl -fL -o "$f" "$BASE/$1-v$2/$1-$2.lgx"
  local got; got=$(shasum -a 256 "$f" | cut -d' ' -f1)
  [ "$got" = "$3" ] || { echo "sha256 mismatch for $f: $got" >&2; exit 1; }
  echo "$f"
}

# Install one package into a profile the way Package Manager lays it out:
# <bucket>/<name>/ holds the variant's files, manifest.json and `variant`.
seed() { # profile lgx bucket name
  local tmp; tmp=$(mktemp -d)
  tar -xzf "$2" -C "$tmp"
  [ -d "$tmp/variants/$VARIANT" ] || { echo "$2 has no $VARIANT variant" >&2; exit 1; }
  local dst="$1/$3/$4"
  mkdir -p "$dst"
  cp -R "$tmp/variants/$VARIANT/." "$dst/"
  cp "$tmp/manifest.json" "$dst/"
  [ -d "$tmp/assets" ] && { mkdir -p "$dst/assets"; cp -R "$tmp/assets/." "$dst/assets/"; }
  echo "$VARIANT" > "$dst/variant"
  rm -rf "$tmp"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  setup)
    [ $# -gt 0 ] || set -- A B
    if [ -z "${FORUM_LGX:-}" ]; then
      nix build "path:$REPO_ROOT#lgx-portable" --max-jobs 2 --cores 4 \
        --accept-flake-config -o "$REPO_ROOT/result-lgx-portable" >&2
      FORUM_LGX="$REPO_ROOT/result-lgx-portable/logos-forum_module-module.lgx"
    fi
    D=$(fetch_dep delivery_module 0.3.2 "$DELIVERY_SHA")
    S=$(fetch_dep storage_module 3.0.0 "$STORAGE_SHA")
    for p in "$@"; do
      dir="$DEMO_ROOT/$p"
      rm -rf "$dir"; mkdir -p "$dir"
      seed "$dir" "$FORUM_LGX" plugins forum_module
      seed "$dir" "$D" modules delivery_module
      seed "$dir" "$S" modules storage_module
      echo "profile $p ready: $dir (forum $(shasum -a 256 "$FORUM_LGX" | cut -c1-12)…)"
    done
    ;;
  app)
    [ "$(uname -s)" = Darwin ] || { echo "app: macOS only (Linux: use the AppImage)" >&2; exit 2; }
    f="$DL/$(basename "$DMG_URL")"
    mkdir -p "$DL"
    [ -f "$f" ] || curl -fL -o "$f" "$DMG_URL"
    [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$DMG_SHA" ] || { echo "dmg sha256 mismatch" >&2; exit 1; }
    mnt=$(hdiutil attach -nobrowse -readonly "$f" | tail -1 | awk -F'\t' '{print $NF}')
    rm -rf "$DEMO_ROOT/LogosBasecamp-0.3.1.app"; mkdir -p "$DEMO_ROOT"
    ditto "$mnt/LogosBasecamp.app" "$DEMO_ROOT/LogosBasecamp-0.3.1.app"
    hdiutil detach "$mnt" -quiet
    echo "Basecamp 0.3.1: $DEMO_ROOT/LogosBasecamp-0.3.1.app"
    ;;
  launch)
    p="${1:?profile name}"
    dir="$DEMO_ROOT/$p"
    [ -d "$dir/plugins/forum_module" ] || { echo "run setup $p first" >&2; exit 1; }
    [ -x "$BIN" ] || { echo "no Basecamp at $APP (run: $0 app)" >&2; exit 1; }
    mkdir -p "$DEMO_ROOT/.pids"
    LOGOS_NO_SCHEME_REGISTER=1 "$BIN" --user-dir "$dir" \
      > "$DEMO_ROOT/$p.stdout.log" 2>&1 &
    echo $! > "$DEMO_ROOT/.pids/$p"
    echo "launched $p (pid $!), log: $DEMO_ROOT/$p.stdout.log"
    ;;
  stop)
    for f in "$DEMO_ROOT"/.pids/*; do
      [ -f "$f" ] || continue
      pid=$(cat "$f")
      kill "$pid" 2>/dev/null && echo "stopped $(basename "$f") ($pid)" || true
      # The launcher execs LogosBasecamp.bin and module hosts are separate
      # processes; stop everything started for this profile.
      pkill -f -- "--user-dir $DEMO_ROOT/$(basename "$f")\$" 2>/dev/null || true
      pkill -f -- "--user-dir $DEMO_ROOT/$(basename "$f") " 2>/dev/null || true
      pkill -f "$DEMO_ROOT/$(basename "$f")/" 2>/dev/null || true
      rm -f "$f"
    done
    # Basecamp takes a few seconds to shut its module hosts down.
    for _ in $(seq 1 20); do
      pgrep -f "$DEMO_ROOT/" >/dev/null || break
      sleep 1
    done
    pgrep -fl "$DEMO_ROOT/" && echo "still running (above) — quit them from the Dock" || true
    ;;
  *)
    sed -n '2,17p' "$0"; exit 2 ;;
esac
