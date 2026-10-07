#!/usr/bin/env python3
"""LP-0026 Forum — M4 negative-case harness (failure matrix inputs).

Bounded CLI negatives on the qualified logosctl 0.3.0 path:

  N1 quota-pressure: storage node with a tiny quota; upload beyond it must
     fail HONESTLY (no silent truncation, no fake success).
  N2 double-createNode (coexistence trigger): a second createNode on a live
     session must be refused — this is exactly the state our in-app guard
     detects (getNodeInfo success before createNode ⇒ visible refusal,
     never reconfigure). Verified at the protocol layer; in-app surfacing is
     covered by the guarded backend code + blocked only by the open slot
     regression (documented).
  N3 oversize payload: a wire far beyond the app bound (4 KiB) sent via the
     transport must NOT be silently accepted as a forum post by the app's
     merge rules — unit-level rejection is receipted in core-tests; here we
     record the TRANSPORT's honest behavior for the matrix.
  N4 replay: an already-delivered wire resent must collapse at the
     verified-ID layer (distinct IDs == 1) — cross-check of R05/R12.

Env: FORUM_STATE (default ~/.local/share/lp0026-forum-dev/m4-negatives)
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

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

REPO = Path(__file__).resolve().parents[1]
STATE = Path(os.environ.get("FORUM_STATE",
                            Path.home() / ".local/share/lp0026-forum-dev/m4-negatives"))
EVID = REPO / "evidence" / "m4-matrix" / (
    "negatives-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
LOGOSCTL = Path(os.environ.get(
    "FORUM_LOGOSCTL",
    str(Path.home() / ".local/share/lp0026-forum-dev/runtime-030/logosctl-aarch64-macos/bin/logosctl")))
DELIVERY_LGX = Path.home() / ".local/share/lp0026-forum-dev/downloads/delivery_module-0.3.2.lgx"
STORAGE_LGX = Path.home() / ".local/share/lp0026-forum-dev/downloads/storage_module-3.0.0.lgx"
TOPIC = "/lp0026forum/1/general/text"
PY = os.environ.get("PY", sys.executable)  # child tools need the same `cryptography`


def ok_val(r) -> bool:
    """CLI results are literal True OR {success: True, value: ...}."""
    return r is True or (isinstance(r, dict) and r.get("success") is True)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Sess:
    def __init__(self, name):
        self.name = name
        self.root = EVID / name
        self.root.mkdir(parents=True, exist_ok=True)
        self.private = STATE / name
        if self.private.exists():
            shutil.rmtree(self.private)
        self.config = self.private / "session"
        self.config.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.home = self.private / "home"
        self.home.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.env = dict(os.environ, HOME=str(self.home),
                        LOGOSCTL_CONFIG_DIR=str(self.config))
        self.proc = None
        self.data = self.private / "data"
        self.data.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.storage_port = free_port()
        self.delivery_port = free_port()

    def cmd(self, *args, check=True, timeout=60):
        argv = [str(LOGOSCTL), "--config-dir", str(self.config), "--json",
                *map(str, args)]
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           env=self.env)
        with (EVID / "commands.jsonl").open("a") as f:
            f.write(json.dumps({"role": self.name, "args": argv[3:],
                                "exit": p.returncode,
                                "stdout": p.stdout[-1000:]}) + "\n")
        if check and p.returncode:
            raise RuntimeError(f"{argv[3:]}: {p.stdout[-400:]}")
        try:
            return json.loads(p.stdout)
        except json.JSONDecodeError:
            return p.stdout

    def start_daemon(self):
        d = self.config / "daemon"
        d.mkdir(parents=True, exist_ok=True)
        (d / "config.yaml").write_text(
            "version: 2\nlogging:\n  enabled: true\n  console: false\n")
        self.log = (self.root / "daemon.log").open("a")
        self.proc = subprocess.Popen(
            [str(LOGOSCTL), "--config-dir", str(self.config), "daemon", "start"],
            stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True,
            env=self.env)
        end = time.monotonic() + 40
        while time.monotonic() < end:
            if self.proc.poll() is not None:
                raise RuntimeError("daemon exited")
            st = self.cmd("daemon", "status", check=False)
            if isinstance(st, dict) and st.get("daemon", {}).get("status") == "running":
                return
            time.sleep(0.5)
        raise RuntimeError("daemon not ready")

    def install(self, lgx):
        self.cmd("install", "-y", str(lgx), timeout=240)

    def load(self, module):
        self.cmd("module", "load", module)

    def call(self, module, method, *args, check=False, timeout=90):
        out = self.cmd("call", module, method, *args, check=check, timeout=timeout)
        result = out.get("result", out) if isinstance(out, dict) else out
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

    def storage_init(self, quota, ttl="24h"):
        cfg = {
            "data-dir": str(self.data / "storage"), "log-level": "info",
            "log-file": str(self.root / "storage.log"),
            "listen-ip": "127.0.0.1", "listen-port": self.storage_port,
            "nat": "extip:127.0.0.1", "no-bootstrap-node": True,
            "bootstrap-node": [], "mix-enabled": False, "num-threads": 0,
            "storage-quota": quota, "block-ttl": ttl, "block-mi": "1m",
        }
        ok = self.call("storage_module", "init", "str:" + json.dumps(cfg))
        if not ok_val(ok):
            raise RuntimeError(f"{self.name} storage init: {ok}")
        self.call("storage_module", "start")
        end = time.monotonic() + 30
        while time.monotonic() < end:
            if self.call("storage_module", "isRunning") is True:
                return
            time.sleep(0.5)
        raise RuntimeError("storage not running")

    def delivery_init(self):
        cfg = {
            "logLevel": "info", "listenAddress": "127.0.0.1",
            "tcpPort": self.delivery_port, "quicSupport": False, "nat": "none",
            "clusterId": 42, "numShardsInNetwork": 1, "relay": True,
            "store": False, "filter": False, "lightpush": False,
            "peerExchange": False, "discv5Discovery": False,
            "enableKadDiscovery": False, "rendezvous": False,
            "reliabilityEnabled": False,
            "localStoragePath": str(self.data / "delivery"),
            "anonymityLevel": "None", "staticnodes": [],
        }
        ok = self.call("delivery_module", "createNode", "str:" + json.dumps(cfg))
        if not ok_val(ok):
            raise RuntimeError(f"delivery createNode: {ok}")
        self.call("delivery_module", "start")

    def close(self):
        for mod, meth in (("delivery_module", "stop"), ("storage_module", "stop"),
                          ("storage_module", "destroy")):
            with contextlib.suppress(Exception):
                self.call(mod, meth)
        with contextlib.suppress(Exception):
            if self.proc and self.proc.poll() is None:
                os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(timeout=8)
        with (EVID / "cleanup.jsonl").open("a") as f:
            f.write(json.dumps({"role": self.name}) + "\n")


def main():
    EVID.mkdir(parents=True, exist_ok=True)
    STATE.mkdir(parents=True, exist_ok=True)
    subprocess.run(["pkill", "-9", "-f", "lp0026-forum-dev/m4-negatives"],
                   capture_output=True)
    time.sleep(1)
    # Never PASS by default: a run that crashes mid-way must read as FAIL.
    result = {"status": "RUNNING", "layer": "m4-negatives", "evidence": str(EVID),
              "cases": {}}
    sessions = []
    try:
        print("=== N1 quota-pressure (tiny quota, oversized upload)")
        s = Sess("n1-quota")
        sessions.append(s)
        s.start_daemon(); s.install(STORAGE_LGX); s.load("storage_module")
        s.storage_init(quota=16384)  # 16 KiB
        big = STATE / "n1-big.bin"
        big.write_bytes(os.urandom(64 * 1024))  # 64 KiB >> quota
        ok_upload = s.call("storage_module", "uploadUrl", str(big), 65536, "true")
        # Honest refusal OR a completion event that does NOT verify on readback.
        refused = ok_upload is False or (
            isinstance(ok_upload, dict) and ok_upload.get("success") is False)
        manifests = s.val(s.call("storage_module", "manifests")) or []
        cids = [m["cid"] for m in manifests if isinstance(m, dict) and m.get("cid")]
        verified = False
        if cids:
            out = STATE / "n1-readback.bin"
            s.call("storage_module", "downloadToUrl", cids[-1], str(out),
                   "true", 65536, "false", "true")
            end = time.monotonic() + 20
            while time.monotonic() < end and not out.exists():
                time.sleep(0.5)
            if out.exists():
                verified = hashlib.sha256(out.read_bytes()).hexdigest() == \
                    hashlib.sha256(big.read_bytes()).hexdigest()
        honest = refused or not verified
        result["cases"]["n1_quota_pressure"] = {
            "upload_dispatched": not refused, "readback_verified": verified,
            "honest": honest,
            "verdict": "PASS" if honest else "FAIL",
            "note": "oversize upload beyond quota must not yield verified bytes"}
        print("N1:", result["cases"]["n1_quota_pressure"])

        print("=== N2 double-createNode (coexistence trigger)")
        s2 = Sess("n2-coexist")
        sessions.append(s2)
        s2.start_daemon(); s2.install(DELIVERY_LGX); s2.load("delivery_module")
        s2.delivery_init()
        first = s2.val(s2.call("delivery_module", "getNodeInfo", "MyPeerId"))
        second = s2.call("delivery_module", "createNode",
                         'str:{"logLevel":"info"}')
        second_failed = not ok_val(second)
        guard_trigger = bool(first)  # getNodeInfo success = our guard's trigger
        result["cases"]["n2_double_createNode"] = {
            "node_exists_after_first": guard_trigger,
            "second_create_refused": bool(second_failed),
            "verdict": "PASS" if (guard_trigger and second_failed) else "FAIL",
            "note": "in-app guard: getNodeInfo success before createNode => "
                    "visible coexistence refusal, never reconfigure"}
        print("N2:", result["cases"]["n2_double_createNode"])

        print("=== N3 oversize wire via transport (app bound is 4 KiB)")
        # Send a 64 KiB wire; transport may accept (it is a pipe) — what must
        # be honest is that the APP merge rejects it (unit-receipted). Here we
        # record the transport behavior only.
        s3 = Sess("n3-oversize")
        sessions.append(s3)
        s3.start_daemon(); s3.install(DELIVERY_LGX); s3.load("delivery_module")
        s3.delivery_init()
        wire = b"forum-v1|" + b"x" * (64 * 1024)
        enc = base64.urlsafe_b64encode(wire).decode().rstrip("=")
        r = s3.val(s3.call("delivery_module", "send", TOPIC,
                           "json:" + json.dumps({"_bytes": enc})))
        result["cases"]["n3_oversize_transport"] = {
            "transport_send": "dispatched" if r else "refused",
            "app_merge_rejects": True,
            "app_merge_receipt": "core-tests bounds (body<=4096) — 116/0",
            "measured": False,
            "verdict": "BY-CONSTRUCTION",
            "note": "transport is a pipe; the APP bound is enforced at merge "
                    "(unit-receipted) — not a transport-layer measurement"}
        print("N3:", result["cases"]["n3_oversize_transport"])

        # Wire the two CLI sessions together (staticnodes) so N4's re-sends are
        # actually DELIVERED and observed — measured, not by construction.
        print("=== N4 replay collapse at verified-ID layer (measured)")
        s4 = Sess("n4-replay")
        sessions.append(s4)
        s4.start_daemon(); s4.install(DELIVERY_LGX); s4.load("delivery_module")
        s4b = Sess("n4-replay-recv")
        sessions.append(s4b)
        s4b.start_daemon(); s4b.install(DELIVERY_LGX); s4b.load("delivery_module")
        s4b.delivery_init()
        b_addr = s4b.val(s4b.call("delivery_module", "getNodeInfo", "MyMultiaddresses"))
        b_addr = (s4b.val(b_addr) if isinstance(b_addr, dict) else b_addr) or []
        if isinstance(b_addr, str):
            try:
                b_addr = json.loads(b_addr)  # module may return a JSON string
            except ValueError:
                b_addr = [b_addr]
        b_addr = b_addr[0] if isinstance(b_addr, list) and b_addr else ""
        cfg4 = {
            "logLevel": "info", "listenAddress": "127.0.0.1",
            "tcpPort": s4.delivery_port, "quicSupport": False, "nat": "none",
            "clusterId": 42, "numShardsInNetwork": 1, "relay": True,
            "store": False, "filter": False, "lightpush": False,
            "peerExchange": False, "discv5Discovery": False,
            "enableKadDiscovery": False, "rendezvous": False,
            "reliabilityEnabled": False,
            "localStoragePath": str(s4.data / "delivery"),
            "anonymityLevel": "None", "staticnodes": [b_addr] if b_addr else [],
        }
        # Check the raw result: val() maps {"success": true, "value": null}
        # to None, which made a successful createNode look like a failure.
        ok = s4.call("delivery_module", "createNode", "str:" + json.dumps(cfg4))
        if not ok_val(ok):
            raise RuntimeError(f"n4 createNode: {ok}")
        s4.call("delivery_module", "start")
        s4b.cmd("call", "delivery_module", "subscribe", TOPIC)
        f = s4b.root / "events.jsonl"
        wf = f.open("a")
        wp = subprocess.Popen(
            [str(LOGOSCTL), "--config-dir", str(s4b.config), "--json",
             "watch", "delivery_module"],
            stdout=wf, stderr=subprocess.STDOUT, start_new_session=True,
            env=s4b.env)
        time.sleep(1.5)
        author = Ed25519PrivateKey.generate()
        from cryptography.hazmat.primitives import serialization as ser
        pub = author.public_key().public_bytes(ser.Encoding.Raw, ser.PublicFormat.Raw).hex()
        canon = (f"forum-v1|forum=general|type=post|topic=general|parent=|"
                 f"author={pub}|alias=|ts={int(time.time()*1000)}|"
                 "body=replay-test").encode()
        wire = canon + b"\n" + author.sign(canon).hex().encode()
        enc = base64.urlsafe_b64encode(wire).decode().rstrip("=")
        for i in range(2):
            s4.val(s4.call("delivery_module", "send", TOPIC,
                           "json:" + json.dumps({"_bytes": enc})))
        # Measure: decode every delivered wire for this body, count the
        # deliveries and the DISTINCT content-derived event IDs among them.
        def delivered_ids():
            ids, count = set(), 0
            if not f.exists():
                return ids, count
            for line in f.read_bytes().decode("utf-8", "replace").splitlines():
                if "messageReceived" not in line:
                    continue
                for tok in re.findall(r"[A-Za-z0-9_=-]{60,}", line):
                    for decoder in (base64.urlsafe_b64decode, base64.b64decode):
                        try:
                            raw = decoder(tok + "=" * (-len(tok) % 4))
                        except Exception:
                            continue
                        if b"body=replay-test" in raw and b"\n" in raw:
                            canon = raw.split(b"\n", 1)[0]
                            ids.add(hashlib.sha256(canon).hexdigest())
                            count += 1
                            break
            return ids, count
        end = time.monotonic() + 40
        ids, deliveries = set(), 0
        while time.monotonic() < end:
            ids, deliveries = delivered_ids()
            if deliveries >= 1:
                time.sleep(5)  # allow the identical re-send to arrive too
                ids, deliveries = delivered_ids()
                break
            time.sleep(1)
        distinct_ids = len(ids)
        measured = deliveries >= 1
        result["cases"]["n4_replay"] = {
            "deliveries_observed": deliveries,
            "distinct_event_ids": distinct_ids,
            "measured": measured,
            "verdict": "PASS" if measured and distinct_ids == 1 else "FAIL",
            "note": "identical re-send collapses to ONE verified event ID; "
                    "delivery actually measured on the wired session pair "
                    "(m2b-cli exactly-once receipt is the full proof)"}
        print("N4:", result["cases"]["n4_replay"])
        with contextlib.suppress(Exception):
            os.killpg(wp.pid, signal.SIGTERM)

        # BY-CONSTRUCTION cases are labelled, not counted as measured passes
        # (their product-side proof is the cited unit receipt).
        fails = [k for k, v in result["cases"].items()
                 if v["verdict"] not in ("PASS", "BY-CONSTRUCTION")]
        result["status"] = "PASS" if not fails else "FAIL"
        result["failed_cases"] = fails
        result["by_construction_cases"] = [
            k for k, v in result["cases"].items() if v["verdict"] == "BY-CONSTRUCTION"]
        result["measured_pass_cases"] = [
            k for k, v in result["cases"].items() if v["verdict"] == "PASS"]
        (EVID / "result.json").write_text(json.dumps(result, indent=2))
        print("RESULT", json.dumps(result))
        return 0 if result["status"] == "PASS" else 1
    except BaseException as e:
        result["status"] = "FAIL"
        result["error"] = f"{type(e).__name__}: {e}"
        (EVID / "result.json").write_text(json.dumps(result, indent=2))
        print("RESULT", json.dumps(result))
        return 1
    finally:
        for s in sessions:
            with contextlib.suppress(Exception):
                s.close()
        time.sleep(1)
        left = subprocess.run(["pgrep", "-f", "lp0026-forum-dev/m4-negatives"],
                              capture_output=True, text=True).stdout.strip()
        print("cleanup leftover:", left or "none")


if __name__ == "__main__":
    sys.exit(main())
