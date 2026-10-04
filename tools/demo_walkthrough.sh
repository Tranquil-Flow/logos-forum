#!/usr/bin/env bash
# LP-0026 Forum — narrated demo walkthrough (recording-ready).
#
# Runs the REAL verification surface in order, with scene headers a narrator
# can read. Hard-fail commands are product claims; soft commands are gates
# that may legitimately NO-GO (they print their verdict either way).
#
# This script rehearses the exact sequence of the recorded demo. Usage:
#   bash tools/demo_walkthrough.sh            # full rehearsal
#   DEMO_SKIP_SLOW=1 bash tools/demo_walkthrough.sh   # skip TTL-wait scenes
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PY="${PY:-python3}"
# Harness python must provide `cryptography` (the only third-party dep). Either
# `pip install cryptography`, or use the pinned one from the flake:
#   PY="$(nix build path:$PWD#harness-python --no-link --print-out-paths)/bin/python3"
"$PY" -c 'import cryptography' 2>/dev/null || {
  echo "error: $PY cannot import 'cryptography' (pip install cryptography, or set PY — see above)" >&2
  exit 2
}
SLOW="${DEMO_SKIP_SLOW:-0}"

run_cmd() { # hard-fail: product claims
  echo ""
  echo "── \$ $*"
  "$@" || { echo "DEMO ABORT: command failed: $*"; exit 1; }
}

run_soft() { # validators may NO-GO; verdict is the content
  echo ""
  echo "── \$ $*"
  "$@" || echo "(soft gate returned non-zero — verdict above is the content)"
}

banner() {
  echo ""
  echo "============================================================"
  echo "SCENE $1: $2"
  echo "============================================================"
}

banner 1 "What this is"
cat <<'EOF'
LP-0026 contender: a text-first Logos Basecamp forum.
- Privacy-required posting (Required Mix) — never a silent plain fallback.
- Durable outbox: store-before-send, duplicate-free retry.
- Verifiable history: per-archive signed inventories, no founder key.
- Honest states: pending / refused / degraded are visible, never invented.
EOF

banner 2 "Domain core — contracts under test (fast, deterministic)"
run_cmd nix build "path:$REPO_ROOT#core-tests" -L --max-jobs 2 --cores 4 --accept-flake-config
run_cmd cat result/test-output.txt

banner 3 "Native module build + package (both variants)"
run_cmd nix build "path:$REPO_ROOT" -L --max-jobs 2 --cores 4 --accept-flake-config
run_cmd nix build "path:$REPO_ROOT#lgx" --max-jobs 2 --cores 4 --accept-flake-config -o result-lgx-dev
run_cmd nix build "path:$REPO_ROOT#lgx-portable" --max-jobs 2 --cores 4 --accept-flake-config -o result-lgx-rel
echo "dev variant:    $(tar -xzOf result-lgx-dev/logos-forum_module-module.lgx manifest.json | python3 -c 'import json,sys; print(list(json.load(sys.stdin)["main"].keys()))')"
echo "release variant: $(tar -xzOf result-lgx-rel/logos-forum_module-module.lgx manifest.json | python3 -c 'import json,sys; print(list(json.load(sys.stdin)["main"].keys()))')"

banner 4 "Hermetic UI suite — honest refusal keeps your text"
run_cmd nix build "path:$REPO_ROOT#integration-test" -L --max-jobs 2 --cores 4 --accept-flake-config
grep -E "passed|failed" evidence/m2-core/integration-*.log | tail -3

banner 5 "Live transport — Required send over local Mix (real modules)"
echo "4 loopback Mix relays + 2 app instances. Sender posts under Required;"
echo "the receiver renders it; the sender's own log carries the Mix trace."
run_soft bash tools/m1_run.sh

banner 6 "Durability at the protocol layer — outage, crash, exactly-once"
echo "Signed wire → Required send → relays die (honest failure) → signed wire"
echo "retained on disk → relays return → ORIGINAL bytes resent → one event ID."
run_soft "$PY" tools/m2b_cli.py

if [ "$SLOW" != "1" ]; then
  banner 7 "Archives — two non-author roles, finite retention, loss/repair"
  echo "Storage v3.0.0 on the qualified CLI: both archives hold the corpus,"
  echo "inventories signed with ARCHIVE keys (not the author's), a short-TTL"
  echo "expiry control fires, refresh restores, and one archive can be lost."
  run_soft env FORUM_LOGOSCTL="${FORUM_LOGOSCTL:-$HOME/.local/share/lp0026-forum-dev/runtime-030/logosctl-aarch64-macos/bin/logosctl}" "$PY" tools/m3_storage.py

  banner 8 "Fresh-reader discovery — nothing injected"
  echo "The reader knows only the public relays + topic. It receives (or"
  echo "queries the retained) SIGNED announce, then verifies the whole chain:"
  echo "announce → CID → bytes → every post signature."
  run_soft env FORUM_LOGOSCTL="${FORUM_LOGOSCTL:-$HOME/.local/share/lp0026-forum-dev/runtime-030/logosctl-aarch64-macos/bin/logosctl}" "$PY" tools/m3_discovery.py
else
  banner 7-8 "Skipped (DEMO_SKIP_SLOW=1) — receipts: evidence/m3-archive/"
fi

banner 9 "Failure matrix — every claim hash-bound"
run_soft "$PY" tools/m4_negatives.py
run_soft "$PY" tools/m4_matrix.py
echo ""
sed -n '1,20p' docs/MATRIX.md

banner 10 "Honest closing"
cat <<'EOF'
Receipted locally: R01-R13 (PASS); R14/R15 (PARTIAL until the remote CI
run, the public catalog and the video exist); R16 (NOT RUN — organic use
cannot be produced by the author). See STATUS.md for what remains. Nothing
here claims publication, catalog listing, or organic use that has not actually
happened.
EOF
echo ""
echo "DEMO WALKTHROUGH COMPLETE"
