#!/usr/bin/env python3
"""LP-0026 Forum — M3 storage lifecycle + archive inventory harness.

Proves on the pinned Storage v3.0.0 (CLI session path — the host path that
works; the nix-built storage module has an init defect recorded in STATUS.md):

  1. Two explicit archive roles (A, B) on loopback, NO public bootstrap.
  2. Signed TECHNICAL TEST DATA corpus uploaded to both archives with
     finite TTL + explicit advertise=true (hosting is consentful).
  3. Byte-exact readback + sha256 verification from BOTH archives (R07).
  4. Per-ARCHIVE signed inventories (archive keys are NOT the author's key —
     non-author issuance, R06/R07) built from verified coverage, verified
     independently (same algorithm as src/archive/archive_core.cpp).
  5. Reader/provider separation: an advertise=false upload must read back
     locally but report getAdvertise()==false (R10).
  6. Finite retention positive control: a short-TTL upload EXPIRES after the
     refresh stops (zero-TTL is NOT treated as permanent), and a re-upload
     (refresh) restores it (R11).
  7. Loss/repair: one archive loses its data dir; the survivor's inventory +
     readback still verify the corpus (second-role verifiability, R07/R09).

Env: FORUM_STATE (default ~/.local/share/lp0026-forum-dev/m3-storage)
"""
import base64
import contextlib
import datetime
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
)
from cryptography.hazmat.primitives import serialization

REPO = Path(__file__).resolve().parents[1]
STATE = Path(os.environ.get("FORUM_STATE",
                            Path.home() / ".local/share/lp0026-forum-dev/m3-storage"))
EVID = REPO / "evidence" / "m3-archive" / (
    "storage-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
LOGOSCTL = Path(os.environ.get(
    "FORUM_LOGOSCTL",
    str(Path.home() / ".local/share/lp0026-forum-dev/runtime/logosctl-aarch64-macos/bin/logosctl")))
STORAGE_LGX = Path(os.environ.get(
    "FORUM_STORAGE_LGX",
    str(Path.home() / ".local/share/lp0026-forum-dev/downloads/storage_module-3.0.0.lgx")))
TOPIC = "/lp0026forum/1/general/text"
TTL_MAIN = "24h"       # main corpus retention ("1h" is rejected by the v3.0.0 parser — probed; 24h/30m/5m/2m/1m all accepted)
TTL_SHORT = "1m"       # expiry-control window (probed accepted)
BLOCK_MI = "1m"        # maintenance interval (documented units)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def canonical_post(body: str, key: Ed25519PrivateKey, ts_ms: int) -> bytes:
    """Same canonical rules as src/core/forum_core.cpp (verbatim escape)."""
    def esc(x: str) -> str:
        return (x.replace("\\", "\\\\").replace("|", "\\p")
                 .replace("\n", "\\n").replace("\r", "\\r"))
    pub = key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
    canon = ("forum-v1|forum=general|type=post|topic=general|parent=|"
             f"author={pub}|alias=|ts={ts_ms}|body={esc(body)}").encode()
    return canon + b"\n" + key.sign(canon).hex().encode()


class Archive:
    """One storage archive role (logosctl session hosting storage_module)."""

    def __init__(self, name: str):
        self.name = name
        self.root = EVID / name
        self.root.mkdir(parents=True, exist_ok=True)
        self.private = STATE / name
        if self.private.exists():
            shutil.rmtree(self.private)
        self.config = self.private / "session"
        self.config.mkdir(parents=True, exist_ok=True, mode=0o700)
        # HOME isolation (predecessor runtime.py lesson): the storage module
        # reads/persists ~/.logos_storage — without a private HOME the daemon
        # auto-initializes from a stale public-network config and a later
        # explicit init hits "context already initialized".
        self.home = self.private / "home"
        self.home.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.env = dict(os.environ, HOME=str(self.home),
                        LOGOSCTL_CONFIG_DIR=str(self.config))
        self.proc = None
        self.watch = None
        self.port = free_port()
        self.data = self.private / "storage-data"
        self.data.mkdir(parents=True, exist_ok=True, mode=0o700)

    def cmd(self, *args, check=True, timeout=60):
        argv = [str(LOGOSCTL), "--config-dir", str(self.config), "--json", *map(str, args)]
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           env=self.env)
        with (EVID / "commands.jsonl").open("a") as f:
            f.write(json.dumps({"role": self.name, "args": list(map(str, args)),
                                "exit": p.returncode,
                                "stdout": p.stdout[-1500:],
                                "stderr": p.stderr[-800:]}) + "\n")
        if check and p.returncode:
            raise RuntimeError(f"{args}: {p.stdout[-600:]} {p.stderr[-600:]}")
        try:
            return json.loads(p.stdout)
        except json.JSONDecodeError:
            return p.stdout

    def start_daemon(self):
        d = self.config / "daemon"
        d.mkdir(parents=True, exist_ok=True)
        (d / "config.yaml").write_text(
            "version: 2\nlogging:\n  enabled: true\n  console: false\n"
            "  max_size_mb: 10\n  max_files: 3\n")
        self.log = (self.root / "daemon.log").open("a")
        self.proc = subprocess.Popen(
            [str(LOGOSCTL), "--config-dir", str(self.config), "daemon", "start"],
            stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True,
            env=self.env)
        end = time.monotonic() + 40
        while time.monotonic() < end:
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.name} daemon exited {self.proc.returncode}")
            try:
                st = self.cmd("daemon", "status", check=False)
                if isinstance(st, dict) and st.get("daemon", {}).get("status") == "running":
                    return
            except Exception:
                pass
            time.sleep(0.5)
        raise RuntimeError(f"{self.name} daemon not ready")

    def install_storage(self):
        self.cmd("install", "-y", str(STORAGE_LGX), timeout=240)
        self.cmd("module", "load", "storage_module")

    def start_watch(self):
        self.watch = self.root / "events.jsonl"
        f = self.watch.open("a")
        self.watch_proc = subprocess.Popen(
            [str(LOGOSCTL), "--config-dir", str(self.config), "--json",
             "watch", "storage_module"],
            stdout=f, stderr=subprocess.STDOUT, start_new_session=True,
            env=self.env)
        time.sleep(1.0)

    def call(self, method, *args, check=True, timeout=90):
        out = self.cmd("call", "storage_module", method, *args,
                       check=check, timeout=timeout)
        result = out.get("result", out) if isinstance(out, dict) else out
        if check and isinstance(result, dict) and result.get("success") is False:
            raise RuntimeError(f"{method}: {out}")
        return result

    @staticmethod
    def val(x):
        if isinstance(x, dict) and "value" in x:
            x = x["value"]
        if isinstance(x, str):
            try:
                return json.loads(x)
            except ValueError:
                pass
        return x

    def init_node(self, ttl: str, bootstrap=None):
        cfg = {
            "data-dir": str(self.data),
            "log-level": "info",  # lowercase — v3.0.0 parser is case-sensitive (probed)
            "log-file": str(self.root / "storage.log"),
            "listen-ip": "127.0.0.1",
            "listen-port": self.port,
            "nat": "extip:127.0.0.1",
            "no-bootstrap-node": not bool(bootstrap),
            "bootstrap-node": list(bootstrap or []),
            "mix-enabled": False,
            "num-threads": 0,  # 0=auto — explicit 1 is rejected by v3.0.0 init (probed)
            "storage-quota": 67108864,
            "block-ttl": ttl,
            "block-mi": BLOCK_MI,
        }
        (self.root / "storage-config.json").write_text(json.dumps(cfg, indent=2))
        ok = self.call("init", "str:" + json.dumps(cfg))
        if ok is not True:
            raise RuntimeError(f"{self.name} init failed: {ok}")
        ok = self.call("start")
        if ok is not True:
            raise RuntimeError(f"{self.name} start failed: {ok}")
        end = time.monotonic() + 30
        while time.monotonic() < end:
            if self.call("isRunning", check=False) is True:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError(f"{self.name} not running")
        # Watch must start AFTER init+start: `logosctl watch` before init makes
        # init return False (probed A/B, config-probe5) — the event subscription
        # interferes with the module's initialization path.
        self.start_watch()

    def peer_multiaddr(self) -> str:
        pid = self.val(self.call("peerId"))
        if isinstance(pid, dict):
            pid = pid.get("peerId") or pid.get("value") or str(pid)
        return f"/ip4/127.0.0.1/tcp/{self.port}/p2p/{pid}"

    def _cids(self):
        manifests = self.val(self.call("manifests", check=False)) or []
        if not isinstance(manifests, list):
            return set()
        return {m["cid"] for m in manifests if isinstance(m, dict) and m.get("cid")}

    def upload(self, path: Path, advertise: str) -> str:
        before = self._cids()
        self.call("uploadUrl", str(path), 65536, advertise)
        end = time.monotonic() + 60
        while time.monotonic() < end:
            new = self._cids() - before
            if new:
                return sorted(new)[-1]
            time.sleep(0.5)
        raise RuntimeError(f"{self.name}: no new manifest cid after upload")

    def readback(self, cid: str, out: Path, local: str, advertise: str) -> bytes:
        self.call("downloadToUrl", cid, str(out), local, 65536, "false", advertise)
        end = time.monotonic() + 45
        while time.monotonic() < end:
            if out.exists() and out.stat().st_size > 0:
                return out.read_bytes()
            time.sleep(0.5)
        raise RuntimeError(f"{self.name}: readback of {cid} produced no bytes")

    def advertise_of(self, cid: str) -> bool:
        v = self.val(self.call("getAdvertise", cid, check=False))
        return bool(v)

    def exists(self, cid: str) -> bool:
        v = self.val(self.call("exists", cid, check=False))
        return bool(v)

    def close(self, destroy: bool = True):
        with contextlib.suppress(Exception):
            if getattr(self, "watch_proc", None):
                os.killpg(self.watch_proc.pid, signal.SIGTERM)
        with contextlib.suppress(Exception):
            self.call("stop", check=False)
            end = time.monotonic() + 15
            while time.monotonic() < end and self.call("isRunning", check=False) is True:
                time.sleep(0.5)
        if destroy:
            with contextlib.suppress(Exception):
                self.call("destroy", check=False)
        with contextlib.suppress(Exception):
            if self.proc and self.proc.poll() is None:
                os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(timeout=8)
        with (EVID / "cleanup.jsonl").open("a") as f:
            f.write(json.dumps({"role": self.name}) + "\n")


def inventory_for(archive_pub: str, epoch: int, cid: str, sha: str, size: int,
                  first_id: str, last_id: str, count: int,
                  author_key: Ed25519PrivateKey, archive_key: Ed25519PrivateKey,
                  forum: str = "general") -> dict:
    """Build + sign a per-archive inventory (mirror of archive_core.cpp)."""
    def esc(x: str) -> str:
        return (x.replace("\\", "\\\\").replace("|", "\\p")
                 .replace("\n", "\\n").replace("\r", "\\r"))
    seg = f"{cid}:{sha}:{size}:{count}:{first_id}:{last_id}"
    canon = ("archive-v1|"
             f"archive={archive_pub}|"
             f"epoch={epoch}|"
             f"forum={esc(forum)}|"
             "predecessor=|"
             f"posts={count}|"
             f"created={int(time.time()*1000)}|"
             f"seg={seg}").encode()
    sig = archive_key.sign(canon)
    sig_hex = sig.hex()  # bytes.hex() is already str in py3
    return {"canonical": canon.decode(), "signature": sig_hex,
            "id": hashlib.sha256(canon).hexdigest(),
            "archive_pub": archive_pub, "epoch": epoch,
            "author_pub": author_key.public_key().public_bytes(
                serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()}


def verify_inventory_py(inv: dict, trusted_archive_pub: str) -> bool:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    canon = inv["canonical"].encode()
    if not canon.startswith(b"archive-v1|"):
        return False
    if hashlib.sha256(canon).hexdigest() != inv["id"]:
        return False
    if f"archive={trusted_archive_pub}|" not in inv["canonical"]:
        return False
    try:
        Ed25519PublicKey.from_public_bytes(bytes.fromhex(trusted_archive_pub)) \
            .verify(bytes.fromhex(inv["signature"]), canon)
    except Exception:
        return False
    return True


def main():
    EVID.mkdir(parents=True, exist_ok=True)
    STATE.mkdir(parents=True, exist_ok=True)
    result = {"status": "FAIL", "layer": "m3-storage-lifecycle",
              "evidence": str(EVID), "claims": []}
    author = Ed25519PrivateKey.generate()          # post author (harness)
    arch_a_key = Ed25519PrivateKey.generate()      # ARCHIVE A own key
    arch_b_key = Ed25519PrivateKey.generate()      # ARCHIVE B own key
    arch_a_pub = arch_a_key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
    arch_b_pub = arch_b_key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
    author_pub = author.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
    assert arch_a_pub != author_pub and arch_b_pub != author_pub

    A = Archive("archive-a")
    B = Archive("archive-b")
    try:
        print("=== 1/7 corpus (TECHNICAL TEST DATA, signed, 5 posts)")
        posts = [canonical_post(f"TECHNICAL TEST DATA: M3 retention post {i}",
                                author, int(time.time() * 1000) + i)
                 for i in range(5)]
        corpus = b"\n".join(posts)
        corpus_sha = hashlib.sha256(corpus).hexdigest()
        corpus_file = STATE / "corpus.txt"
        corpus_file.write_bytes(corpus)
        first_id = hashlib.sha256(posts[0].rsplit(b"\n", 1)[0]).hexdigest()
        last_id = hashlib.sha256(posts[-1].rsplit(b"\n", 1)[0]).hexdigest()
        result["corpus"] = {"posts": 5, "bytes": len(corpus), "sha256": corpus_sha,
                            "author_is_archive": False}

        print("=== 2/7 archive roles up (loopback, no public bootstrap)")
        for arch in (A, B):
            arch.start_daemon()
            arch.install_storage()
        A.init_node(TTL_MAIN)
        B.init_node(TTL_MAIN)
        A_addr = A.peer_multiaddr()
        B_addr = B.peer_multiaddr()
        result["archives"] = {"a": A_addr, "b": B_addr, "public_bootstrap": False}

        print("=== 3/7 upload corpus to BOTH archives (advertise=true, explicit)")
        cid_a = A.upload(corpus_file, "true")
        cid_b = B.upload(corpus_file, "true")
        result["cids"] = {"a": cid_a, "b": cid_b}
        rb_a = A.readback(cid_a, STATE / "rb-a.txt", "true", "true")
        rb_b = B.readback(cid_b, STATE / "rb-b.txt", "true", "true")
        if hashlib.sha256(rb_a).hexdigest() != corpus_sha:
            raise RuntimeError("archive A readback hash mismatch")
        if hashlib.sha256(rb_b).hexdigest() != corpus_sha:
            raise RuntimeError("archive B readback hash mismatch")
        result["claims"] += ["two-archives-hold-verifiable-bytes",
                             "byte-exact-readback-both-archives"]

        print("=== 4/7 per-archive NON-AUTHOR signed inventories")
        inv_a = inventory_for(arch_a_pub, 1, cid_a, corpus_sha, len(corpus),
                              first_id, last_id, 5, author, arch_a_key)
        inv_b = inventory_for(arch_b_pub, 1, cid_b, corpus_sha, len(corpus),
                              first_id, last_id, 5, author, arch_b_key)
        (EVID / "inventory-a.json").write_text(json.dumps(inv_a, indent=2))
        (EVID / "inventory-b.json").write_text(json.dumps(inv_b, indent=2))
        if not verify_inventory_py(inv_a, arch_a_pub):
            raise RuntimeError("inventory A failed independent verification")
        if not verify_inventory_py(inv_b, arch_b_pub):
            raise RuntimeError("inventory B failed independent verification")
        if verify_inventory_py(inv_a, arch_b_pub):
            raise RuntimeError("cross-archive key confusion not rejected")
        result["claims"] += ["non-author-inventories-signed-and-verified",
                             "archive-keys-distinct-from-author-key"]

        print("=== 5/7 reader/provider separation (advertise=false negative)")
        secret_file = STATE / "secret.txt"
        secret_file.write_bytes(b"TECHNICAL TEST DATA: private reader copy")
        cid_priv = A.upload(secret_file, "false")
        rb_priv = A.readback(cid_priv, STATE / "rb-priv.txt", "true", "true")
        if b"private reader copy" not in rb_priv:
            raise RuntimeError("private local readback failed")
        if A.advertise_of(cid_priv) is not False:
            raise RuntimeError("advertise=false upload reports advertised!")
        result["claims"] += ["private-upload-not-advertised-local-read-ok"]

        print("=== 6/7 finite retention positive control (short TTL expires)")
        short_file = STATE / "short.txt"
        short_file.write_bytes(b"TECHNICAL TEST DATA: short-lived segment")
        cid_short = A.upload(short_file, "true")
        if not A.exists(cid_short):
            raise RuntimeError("short-TTL upload missing before expiry window")
        wait_s = 60 + 2 * 60 + 30  # ttl + 2 maintenance intervals + margin
        print(f"waiting {wait_s}s for expiry (block-ttl={TTL_SHORT})")
        # NOTE: the main node TTL is TTL_MAIN; the expiry control uses a
        # dedicated node with the short TTL to keep the corpus stable.
        C = Archive("archive-ttl-control")
        try:
            C.start_daemon()
            C.install_storage()
            C.init_node(TTL_SHORT)  # starts its own watch after init
            cid_c = C.upload(short_file, "true")
            if not C.exists(cid_c):
                raise RuntimeError("ttl-control upload missing at t0")
            time.sleep(wait_s)
            if C.exists(cid_c):
                raise RuntimeError("zero-TTL/finite-TTL expiry did NOT happen")
            result["claims"] += ["finite-ttl-expiry-positive-control"]
            # Refresh (re-upload) restores the bytes before further decay.
            cid_c2 = C.upload(short_file, "true")
            if not C.exists(cid_c2):
                raise RuntimeError("refresh re-upload missing")
            rb_c = C.readback(cid_c2, STATE / "rb-c.txt", "true", "true")
            if b"short-lived segment" not in rb_c:
                raise RuntimeError("refresh readback mismatch")
            result["claims"] += ["finite-ttl-refresh-restores-bytes"]
        finally:
            C.close()

        print("=== 7/7 loss/repair: archive A data dir wiped; B still verifies")
        A.close(destroy=True)
        shutil.rmtree(A.data, ignore_errors=True)
        rb_b2 = B.readback(cid_b, STATE / "rb-b2.txt", "true", "true")
        if hashlib.sha256(rb_b2).hexdigest() != corpus_sha:
            raise RuntimeError("survivor readback mismatch after A loss")
        if not verify_inventory_py(inv_b, arch_b_pub):
            raise RuntimeError("survivor inventory failed after A loss")
        result["claims"] += ["second-archive-verifies-after-one-loss"]

        result["status"] = "PASS"
        (EVID / "result.json").write_text(json.dumps(result, indent=2))
        print("RESULT", json.dumps(result))
        return 0
    except BaseException as e:
        result["error"] = f"{type(e).__name__}: {e}"
        (EVID / "result.json").write_text(json.dumps(result, indent=2))
        print("RESULT", json.dumps(result))
        return 1
    finally:
        for a in (A, B):
            with contextlib.suppress(Exception):
                a.close()
        time.sleep(1)
        left = subprocess.run(["pgrep", "-f", "lp0026-forum-dev/m3-storage"],
                              capture_output=True, text=True).stdout.strip()
        print("cleanup leftover:", left or "none")


if __name__ == "__main__":
    sys.exit(main())
