#!/usr/bin/env bash
# Build and test the Linux outputs inside a nixos/nix container.
# Usage: tools/linux_build.sh [attr ...]   (default: core-tests integration-test lgx-portable)
# The container's native platform is used (aarch64-linux on Apple silicon,
# x86_64-linux on x86 hosts). /nix is kept in the docker volume lp0026-nix.
# Memory: the kernel OOM log showed the `nix` process itself (5.2 GB RSS)
# being killed, not the compiler — evaluation heap + build in one process.
# Each attribute is therefore evaluated to a .drv first and realised in a
# fresh process. Parallelism stays modest (Docker Desktop's VM is 8 GB).
#
# Windows: the x86_64-windows package is a mingw cross build that the
# module builder realises only on x86_64-linux. On Apple silicon run it in an
# emulated amd64 container with its own /nix volume:
#   LINUX_PLATFORM=linux/amd64 tools/linux_build.sh packages.x86_64-windows.lgx-portable
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ATTRS=("$@")
[ ${#ATTRS[@]} -gt 0 ] || ATTRS=(core-tests integration-test lgx-portable)
STAMP="$(date +%Y%m%d-%H%M%S)"
PLATFORM="${LINUX_PLATFORM:-}"
VOLUME=lp0026-nix
KIND=linux
if [ -n "$PLATFORM" ]; then
  VOLUME="lp0026-nix-${PLATFORM##*/}"
  KIND="linux-${PLATFORM##*/}"
fi
OUT="$REPO_ROOT/evidence/m5-package/$KIND-$STAMP"
mkdir -p "$OUT"

# Under emulation, translated frames are larger: evaluating the Windows
# cross set overflowed the default 8 MB stack (linux-amd64-20261004-202135).
# HOST_EVAL=1: evaluate on the host and hand the container the derivation
# closure; the container only builds. Evaluating the Windows cross set inside
# the emulated container overflows the evaluator's stack even with
# `ulimit -s unlimited` (linux-amd64-20261004-204935), while the same
# evaluation succeeds natively on macOS.
DRVDIR="$(mktemp -d)"
trap 'rm -rf "$DRVDIR"' EXIT
if [ "${HOST_EVAL:-0}" = 1 ]; then
  for a in "${ATTRS[@]}"; do
    n=${a##*.}
    drv=$(nix path-info --derivation "path:$REPO_ROOT#$a" 2> "$OUT/host-eval-$n.log")
    echo "$drv" | tee -a "$OUT/host-eval-$n.log" > "$DRVDIR/$n.drvpath"
    nix-store --export $(nix-store -qR "$drv") > "$DRVDIR/$n.closure"
    du -h "$DRVDIR/$n.closure" | tee -a "$OUT/host-eval-$n.log"
  done
fi

docker run --rm ${PLATFORM:+--platform "$PLATFORM"} ${PLATFORM:+--ulimit stack=-1:-1} \
  -v "$VOLUME":/nix \
  -v "$REPO_ROOT":/src:ro \
  -v "$OUT":/out \
  -v "$DRVDIR":/drvs:ro \
  -e ATTRS="${ATTRS[*]}" -e LINUX_MAX_JOBS="${LINUX_MAX_JOBS:-1}" -e LINUX_CORES="${LINUX_CORES:-2}" \
  -e EMULATED="${PLATFORM:+1}" \
  nixos/nix:latest sh -c '
    set -e
    [ -n "$EMULATED" ] && { ulimit -s unlimited 2>/dev/null || true; echo "stack: $(ulimit -s)"; }
    cat >> /etc/nix/nix.conf <<CONF
experimental-features = nix-command flakes
extra-substituters = https://cache.nix.logos.co/public
extra-trusted-public-keys = public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=
max-jobs = ${LINUX_MAX_JOBS:-1}
cores = ${LINUX_CORES:-2}
max-substitution-jobs = 2
stalled-download-timeout = 60
download-attempts = 5
${EMULATED:+sandbox = false}
${EMULATED:+filter-syscalls = false}
CONF
    mkdir -p /work && cd /src
    tar --exclude="./result*" --exclude=./evidence --exclude=./.direnv -cf - . | tar -xf - -C /work
    cd /work
    echo "system: $(nix eval --impure --raw --expr builtins.currentSystem)" | tee /out/system.txt
    rc=0
    for a in $ATTRS; do
      # Two steps keep peak memory at max(eval, build) instead of their sum:
      # evaluating the flake alone takes ~3.6 GB, and a single `nix build`
      # process keeps that heap while it downloads and compiles.
      n=${a##*.}; drv=""
      if [ -f "/drvs/$n.drvpath" ]; then
        nix-store --import < "/drvs/$n.closure" > /dev/null 2> "/out/import-$n.log"
        drv=$(cat "/drvs/$n.drvpath")
        echo "host-evaluated $drv" > "/out/eval-$n.log"
      fi
      if { [ -n "$drv" ] || drv=$(nix path-info --derivation "path:/work#$a" 2> "/out/eval-$n.log"); } \
         && echo "$drv" >> "/out/eval-$n.log" \
         && out=$(nix-store --realise "$drv" --add-root "/work/result-$n" --indirect 2> "/out/build-$n.log"); then
        echo "$out" >> "/out/build-$n.log"
        echo "$a rc=0" | tee -a /out/summary.txt
      else
        echo "$a rc=$?" | tee -a /out/summary.txt; rc=1
      fi
    done
    [ -e /work/result-core-tests ] && find -L /work/result-core-tests -maxdepth 2 -type f | head -20 > /out/core-tests-files.txt || true
    # A cached test derivation prints nothing while building; keep its output.
    [ -f /work/result-core-tests/test-output.txt ] && cp /work/result-core-tests/test-output.txt /out/core-tests-output.txt || true
    if [ -e /work/result-lgx-portable ]; then
      ls -la /work/result-lgx-portable/ > /out/lgx-portable-ls.txt 2>&1
      for f in /work/result-lgx-portable/*.lgx; do
        sha256sum "$f" >> /out/lgx-portable-sha256.txt
        tar tzf "$f" > /out/lgx-portable-contents.txt
        tar xzOf "$f" ./manifest.json > /out/lgx-portable-manifest.json 2>/dev/null \
          || tar xzOf "$f" manifest.json > /out/lgx-portable-manifest.json 2>/dev/null || true
        mkdir -p /out/pkg && cp "$f" /out/pkg/
      done
    fi
    exit $rc
  '
# Packages are binaries: keep them next to the repo, not in the evidence.
if [ -d "$OUT/pkg" ]; then
  ART="$REPO_ROOT/../lp0026-forum-artifacts/$KIND-$STAMP"
  mkdir -p "$ART" && mv "$OUT"/pkg/* "$ART"/ && rmdir "$OUT/pkg"
  echo "package: $ART"
fi
echo "evidence: $OUT"
