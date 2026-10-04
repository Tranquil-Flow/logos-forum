#!/usr/bin/env bash
# LP-0026 Forum — repository-owned verification surface.
#
# Targets:
#   core      — Qt-free domain-core + archive tests (nix .#core-tests)
#   ui        — native ui_qml integration tests via logos-qt-mcp (hermetic)
#   protocol  — two-instance Required round trip over local Mix relays
#   package   — .lgx build (dev and portable variants)
#   live      — PUBLIC logos.dev: two instances join via the in-app Connect
#               action; one post round trip (posts labelled test data)
#   history   — PUBLIC logos.dev: author posts and quits; a later reader with
#               an empty store must obtain the post
#   storage   — PUBLIC logos.dev + loopback Logos Storage: save a topic
#               snapshot in-app; a reader that never joins Delivery restores it
#   all-local — core + ui + package; non-zero if any fails (never always-green)
#
# Usage: ./tools/verify.sh <target>
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TARGET="${1:-}"
STATUS_DIR="$REPO_ROOT/evidence/verify-runs"
mkdir -p "$STATUS_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$STATUS_DIR/verify-$TARGET-$STAMP.log"

run_target() {
  local name="$1"; shift
  local log="$STATUS_DIR/verify-$name-$STAMP.log"
  echo "== verify: $name" | tee "$log"
  if "$@" >>"$log" 2>&1; then
    echo "PASS $name" | tee -a "$log"
    return 0
  else
    local rc=$?
    echo "FAIL $name (exit $rc) — see $log" | tee -a "$log"
    return $rc
  fi
}

not_implemented() {
  local name="$1" slice="$2"
  echo "NOT RUN $name — $slice slice not implemented yet (non-execution propagates)" | tee -a "$LOG"
  return 2
}

case "$TARGET" in
  core)
    run_target core sh -c "nix build 'path:$REPO_ROOT#core-tests' -o '$REPO_ROOT/result-core-tests' -L \
      && cat '$REPO_ROOT/result-core-tests/test-output.txt'"
    ;;
  ui)
    run_target ui nix build "path:$REPO_ROOT#integration-test" -L
    ;;
  protocol)
    if [ ! -x "$REPO_ROOT/tools/m1_run.sh" ]; then
      not_implemented protocol "M1 transport"
    else
      run_target protocol "$REPO_ROOT/tools/m1_run.sh"
    fi
    ;;
  package)
    run_target package sh -c "nix build 'path:$REPO_ROOT#lgx' -o '$REPO_ROOT/result-lgx-dev' \
      && nix build 'path:$REPO_ROOT#lgx-portable' -o '$REPO_ROOT/result-lgx-portable'"
    ;;
  live)
    run_target live "$REPO_ROOT/tools/m6_live.sh"
    ;;
  history)
    run_target history "$REPO_ROOT/tools/m6_history.sh"
    ;;
  storage)
    run_target storage "$REPO_ROOT/tools/m7_storage.sh"
    ;;
  store-probe)
    # Dev-launcher M2-GUI probe (slot return, PROP sync, post path). Expects
    # result-lgx-dev/logos-forum_module-module.lgx + dev launcher to exist.
    # The probe process exits 0 when the evidence run itself completed and
    # cleaned up, even if result.json's gate_label is
    # "M2-GUI FAIL". Inspect evidence/m5-package/store-probe-*/.
    run_target store-probe "$REPO_ROOT/tools/store_probe.sh"
    ;;
  all-local)
    rc=0
    "$0" core || rc=1
    "$0" ui || rc=1
    "$0" package || rc=1
    exit $rc
    ;;
  *)
    echo "usage: $0 core|ui|protocol|package|store-probe|live|history|storage|all-local" >&2
    exit 64
    ;;
esac
