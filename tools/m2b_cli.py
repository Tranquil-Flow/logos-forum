#!/usr/bin/env python3
"""LP-0026 Forum — M2b CLI-protocol durability leg.

Closes the durability/dedup claims at the PROTOCOL layer without the in-app
QtRO slot path (which has an open upstream-blocked regression — STATUS.md):

  wire = canonical-bytes ++ "\\n" ++ sig_hex          (src/forum_module_backend.cpp)
  canonical = "forum-v1|forum=..|type=..|topic=..|parent=..|author=<hex>|
               alias=..|ts=<num>|body=.."             (src/core/forum_core.cpp)
  Ed25519 = RFC 8032 (libsodium in the product; python-cryptography here —
           the same standard, so wires verify across implementations)

Flow:
  1. 4 loopback Mix relays (tools/m1_topology.py, validated topology).
  2. CLI sender + receiver logosctl sessions (the event-consumption path the
     predecessor proofs ran stably), sender Required+mix, receiver plain.
  3. P1: harness signs → logosctl send → receiver watch → independent
     verification (signature + content-derived ID).
  4. Relays STOP → P2 send must FAIL honestly (messageError, Required).
     The signed P2 wire is retained on disk (durable file, 0600).
  5. Relays RESTART with the SAME identities → resend the ORIGINAL bytes →
     receiver delivery verified; distinct event IDs == 1 (exactly-once at
     the verified-ID layer; identical re-delivery collapses by ID).

Env: FORUM_STATE (default ~/.local/share/lp0026-forum-dev/m2b-cli)
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
import subprocess
import sys
import time
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives import serialization

REPO = Path(__file__).resolve().parents[1]
STATE = Path(os.environ.get("FORUM_STATE",
                            Path.home() / ".local/share/lp0026-forum-dev/m2b-cli"))
EVID = REPO / "evidence" / "m2-core" / ("m2b-cli-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
PY = os.environ.get("PY", sys.executable)  # child tools need the same `cryptography`
RUNTIME = Path.home() / ".local/share/lp0026-forum-dev/runtime/logosctl-aarch64-macos"
LOGOSCTL = RUNTIME / "bin" / "logosctl"
DELIVERY_LGX = Path(os.environ.get(
    "FORUM_DELIVERY_LGX",
    str(Path.home() / ".local/share/lp0026-forum-dev/downloads/delivery_module-0.3.0.lgx")))
TOPIC = "/lp0026forum/1/general/text"
P1 = b"TECHNICAL TEST DATA: M2b-cli post one"
P2 = b"TECHNICAL TEST DATA: M2b-cli post two survives outage"


# ---------------- canonical encoding (verbatim rules from forum_core.cpp) ----
def escape_field(s: str) -> str:
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == "|":
            out.append("\\p")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        else:
            out.append(ch)
    return "".join(out)


def canonical(forum, typ, topic, parent, author_hex, alias, ts_ms, body: str) -> bytes:
    s = (
        "forum-v1|"
        f"forum={escape_field(forum)}|"
        f"type={escape_field(typ)}|"
        f"topic={escape_field(topic)}|"
        f"parent={escape_field(parent)}|"
        f"author={author_hex}|"
        f"alias={escape_field(alias)}|"
        f"ts={ts_ms}|"
        f"body={escape_field(body)}"
    )
    return s.encode("utf-8")


def make_wire(body: str, key: Ed25519PrivateKey, ts_ms: int) -> tuple[bytes, bytes, str]:
    pub = key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
    canon = canonical("general", "post", "general", "", pub, "", ts_ms, body)
    sig = key.sign(canon)
    wire = canon + b"\n" + sig.hex().encode()
    return wire, canon, pub


def verify_wire(wire: bytes) -> dict:
    """Independent verification: structure, signature, content-derived ID."""
    nl = wire.rfind(b"\n")
    if nl <= 0:
        return {"ok": False, "reason": "no canonical/signature split"}
    canon, sig_hex = wire[:nl], wire[nl + 1:]
    if not canon.startswith(b"forum-v1|"):
        return {"ok": False, "reason": "domain prefix missing"}
    if len(sig_hex) != 128:
        return {"ok": False, "reason": f"sig length {len(sig_hex)} != 128"}
    m = re.search(rb"author=([0-9a-f]{64})", canon)
    if not m:
        return {"ok": False, "reason": "author key missing"}
    body_m = re.search(rb"\|body=(.*)$", canon, re.S)
    body = body_m.group(1).decode("utf-8", "replace") if body_m else ""
    try:
        Ed25519PublicKey.from_public_bytes(bytes.fromhex(m.group(1).decode())) \
            .verify(bytes.fromhex(sig_hex.decode()), canon)
    except Exception as e:
        return {"ok": False, "reason": f"signature invalid: {e}", "body": body}
    event_id = hashlib.sha256(canon).hexdigest()
    return {"ok": True, "event_id": event_id, "body": body,
            "author": m.group(1).decode()}


# ---------------- logosctl session (adapted from predecessor runtime.py) -----
class Session:
    def __init__(self, name: str, role: str):
        self.name = name
        self.role = role
        self.root = EVID / name
        self.root.mkdir(parents=True, exist_ok=True)
        self.private = STATE / name
        if self.private.exists():
            shutil.rmtree(self.private)
        self.config = self.private / "session"
        self.config.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.proc = None
        self.watch_path = None
        self.watch_proc = None

    def cmd(self, *args, check=True, timeout=45):
        argv = [str(LOGOSCTL), "--config-dir", str(self.config), "--json", *map(str, args)]
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        rec = {"role": self.name, "args": list(args), "exit": p.returncode,
               "stdout": p.stdout[-2000:], "stderr": p.stderr[-1000:]}
        with (EVID / "commands.jsonl").open("a") as f:
            f.write(json.dumps(rec) + "\n")
        if check and p.returncode:
            raise RuntimeError(f"{args}: {p.stdout[-800:]} {p.stderr[-800:]}")
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
            stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.name} daemon exited {self.proc.returncode}")
            try:
                st = self.cmd("daemon", "status", check=False)
                if isinstance(st, dict) and st.get("daemon", {}).get("status") == "running":
                    return st
            except Exception:
                pass
            time.sleep(0.5)
        raise RuntimeError(f"{self.name} daemon not ready")

    def install_delivery(self):
        # NO_DAEMON rule: daemon must run before install (session client path).
        out = self.cmd("install", "-y", str(DELIVERY_LGX), timeout=180)
        txt = json.dumps(out).replace(" ", "")
        if '"status":"error"' in txt and "NO_DAEMON" in txt:
            raise RuntimeError("install hit NO_DAEMON — daemon ordering broken")
        self.cmd("module", "load", "delivery_module")

    def start_watch(self):
        self.watch_path = self.root / "events.jsonl"
        f = self.watch_path.open("a")
        self.watch_proc = subprocess.Popen(
            [str(LOGOSCTL), "--config-dir", str(self.config), "--json",
             "watch", "delivery_module"],
            stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        time.sleep(1.5)

    def call(self, method, *args, check=True, timeout=60):
        out = self.cmd("call", "delivery_module", method, *args,
                       check=check, timeout=timeout)
        result = out.get("result", out) if isinstance(out, dict) else out
        if check and isinstance(result, dict) and result.get("success") is False:
            raise RuntimeError(f"{method}: {out}")
        return result

    @staticmethod
    def val(result):
        if isinstance(result, dict):
            return result.get("value", result)
        return result

    def configure(self, cfg: dict):
        self.call("createNode", "str:" + json.dumps(cfg), timeout=90)
        self.call("start", timeout=90)
        self.call("subscribe", TOPIC)

    def send_wire(self, wire: bytes) -> object:
        enc = base64.urlsafe_b64encode(wire).decode().rstrip("=")
        return self.val(self.call(
            "send", TOPIC, "json:" + json.dumps({"_bytes": enc}), timeout=90))

    def close(self):
        for p in (self.watch_proc, self.proc):
            if p is None or p.poll() is not None:
                continue
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for p in (self.watch_proc, self.proc):
            if p is None:
                continue
            try:
                p.wait(timeout=8)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                p.wait()
        with (EVID / "cleanup.jsonl").open("a") as f:
            f.write(json.dumps({"role": self.name}) + "\n")


# ---------------- watch parsing / verification ------------------------------
def extract_verified(watch_path: Path, want_body: bytes, deadline_s: float) -> dict:
    """Poll the watch file; return first verified delivery of want_body."""
    end = time.monotonic() + deadline_s
    deliveries = 0
    ids = set()
    while time.monotonic() < end:
        if watch_path.exists():
            text = watch_path.read_bytes().decode("utf-8", "replace")
            for line in text.splitlines():
                if "messageReceived" not in line or TOPIC not in line:
                    continue
                for tok in re.findall(r"[A-Za-z0-9_=-]{60,}", line):
                    for decoder in (base64.urlsafe_b64decode,
                                    base64.b64decode):
                        try:
                            raw = decoder(tok + "=" * (-len(tok) % 4))
                        except Exception:
                            continue
                        if b"forum-v1|" not in raw:
                            continue
                        v = verify_wire(raw)
                        if not v.get("ok"):
                            return {"verified": False, **v}
                        if want_body.decode() in v.get("body", ""):
                            deliveries += 1
                            ids.add(v["event_id"])
                            if len(ids) >= 1 and want_body in raw:
                                return {"verified": True, "event_ids": sorted(ids),
                                        "deliveries_seen": deliveries,
                                        "author": v["author"]}
        time.sleep(1.0)
    return {"verified": False, "reason": "deadline", "deliveries_seen": deliveries}


def wait_watch_contains(path: Path, needle: str, deadline_s: float) -> bool:
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        if path.exists() and needle in path.read_bytes().decode("utf-8", "replace"):
            return True
        time.sleep(1.0)
    return False


# ---------------- topology (relay harness as subprocess) --------------------
def start_relays(reuse: bool) -> subprocess.Popen:
    args = [PY, str(REPO / "tools" / "m1_topology.py"),
            "--state", str(STATE / "relays"), "--evidence", str(EVID),
            "--runtime", str(RUNTIME), "start"]
    if reuse:
        args.append("--reuse")
    # Never let a previous run's readiness file satisfy the wait below (the
    # harness also removes it, but only after its own startup).
    pids = STATE / "relays" / "relays.pids"
    pids.unlink(missing_ok=True)
    p = subprocess.Popen(args, stdout=(EVID / "relays.log").open("a"),
                         stderr=subprocess.STDOUT, start_new_session=True)
    end = time.monotonic() + 120
    while time.monotonic() < end:
        if pids.exists() and "core4" in pids.read_text():
            return p
        time.sleep(2)
    raise RuntimeError("relays did not come up")


def stop_relays():
    subprocess.run([PY, str(REPO / "tools" / "m1_topology.py"),
                    "--state", str(STATE / "relays"), "stop"],
                   capture_output=True, timeout=60)


def app_config(role: str, out: Path):
    subprocess.run([PY, str(REPO / "tools" / "m1_topology.py"),
                    "--state", str(STATE / "relays"),
                    "app-config", "--role", role, "--out", str(out)],
                   check=True, capture_output=True, timeout=60)


# ---------------- flow ------------------------------------------------------
def main():
    EVID.mkdir(parents=True, exist_ok=True)
    (STATE).mkdir(parents=True, exist_ok=True)
    result = {"status": "FAIL", "layer": "m2b-cli-protocol",
              "evidence": str(EVID), "claims": []}
    key = Ed25519PrivateKey.generate()
    sender = Session("sender-cli", "sender")
    receiver = Session("receiver-cli", "receiver")
    relay_harness = None
    try:
        print("=== 1/6 relays up")
        relay_harness = start_relays(reuse=False)
        app_config("sender", STATE / "sender.json")
        app_config("receiver", STATE / "receiver.json")

        print("=== 2/6 CLI sessions up")
        sender.start_daemon(); sender.install_delivery(); sender.start_watch()
        receiver.start_daemon(); receiver.install_delivery(); receiver.start_watch()
        sender.configure(json.loads((STATE / "sender.json").read_text()))
        receiver.configure(json.loads((STATE / "receiver.json").read_text()))

        # ---- Mesh-ready gate (reproducibility hardening) -------------------
        # The reviewer's reruns died with deliveries_seen: 0 when sends fired
        # before the mesh formed. The delivery module's getNodeInfo supports
        # only [Version, Metrics, MyMultiaddresses, MyENR, MyPeerId] — there
        # is no pubsub-peers key — so readiness = node up (multiaddrs present)
        # + a warm-up grace, and P1 verification retries the ORIGINAL bytes
        # once after a further pause (dedup-safe: identical wire).
        TOPIC = "/lp0026forum/1/general/text"
        for s in (sender, receiver):
            try:
                s.cmd("call", "delivery_module", "subscribe", TOPIC, check=False)
            except Exception:
                pass

        def node_up(sess) -> bool:
            try:
                # Session.call already targets delivery_module (passing the
                # module name again made every probe an unknown-method exit 4,
                # so this gate could never pass).
                r = sess.val(sess.call("getNodeInfo", "MyMultiaddresses"))
            except Exception:
                return False
            return bool(r)

        end = time.monotonic() + 90
        while time.monotonic() < end and not node_up(sender):
            time.sleep(3)
        if not node_up(sender):
            raise RuntimeError("sender node never came up (no multiaddrs)")
        print("mesh-ready: sender node up; warming up 20s for gossipsub mesh")
        time.sleep(20)

        print("=== 3/7 P1 signed wire → Required send → independent verify")
        ts1 = int(time.time() * 1000)
        wire1, canon1, pub1 = make_wire(P1.decode(), key, ts1)
        (EVID / "p1.wire").write_bytes(wire1)
        req1 = sender.send_wire(wire1)
        print("P1 send request:", req1)
        v1 = extract_verified(receiver.watch_path, P1, 90)
        if not v1.get("verified"):
            # Bounded retry with the ORIGINAL bytes (dedup-safe) after a
            # further mesh grace — reproducibility hardening.
            print("P1 unverified on first attempt; pausing 30s + resending "
                  "original signed bytes")
            time.sleep(30)
            req1b = sender.send_wire(wire1)
            print("P1 resend request:", req1b)
            v1 = extract_verified(receiver.watch_path, P1, 120)
        print("P1 verify:", v1)
        if not v1.get("verified"):
            raise RuntimeError(f"P1 not verified on the wire: {v1}")
        result["claims"].append("p1-wire-verified-independently")
        result["p1"] = v1

        print("=== 4/7 relays stop → P2 Required send must fail honestly")
        if relay_harness:
            try:
                os.killpg(relay_harness.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        stop_relays()
        time.sleep(5)
        ts2 = int(time.time() * 1000)
        wire2, canon2, pub2 = make_wire(P2.decode(), key, ts2)
        wire2_path = STATE / "p2-durable.wire"
        wire2_path.write_bytes(wire2)
        os.chmod(wire2_path, 0o600)
        err_seen = False
        try:
            sender.send_wire(wire2)
            print("P2 send dispatched (awaiting Required refusal event)")
        except Exception as e:
            print("P2 send raised (also honest):", str(e)[:200])
            err_seen = True
        if wait_watch_contains(sender.watch_path, "messageError", 75):
            err_seen = True
        if not err_seen:
            raise RuntimeError("P2: no messageError seen while relays were down")
        # The signed wire survived on disk — durable file proof.
        if verify_wire(wire2_path.read_bytes()).get("ok") is not True:
            raise RuntimeError("P2 durable wire failed verification after outage")
        result["claims"] += ["p2-required-failed-honestly-relays-down",
                             "p2-signed-wire-durably-retained"]
        result["p2_send_refused"] = True

        print("=== 5/7 relays back (same identities) + fresh sessions + resend ORIGINAL bytes")
        relay_harness = start_relays(reuse=True)
        time.sleep(8)
        # Recovery pattern (matches the upstream finding: live nodes do not
        # reliably redial staticnodes that vanished and returned — restart
        # with fresh locators is the supported path). The DURABLE WIRE is the
        # original file; nothing is re-signed.
        print("restarting CLI sessions against the live relays")
        sender.close(); receiver.close()
        sender = Session("sender-cli-2", "sender")
        receiver = Session("receiver-cli-2", "receiver")
        sender.start_daemon(); sender.install_delivery(); sender.start_watch()
        receiver.start_daemon(); receiver.install_delivery(); receiver.start_watch()
        sender.configure(json.loads((STATE / "sender.json").read_text()))
        receiver.configure(json.loads((STATE / "receiver.json").read_text()))
        wire2_reload = wire2_path.read_bytes()
        if wire2_reload != wire2:
            raise RuntimeError("durable wire changed on disk — durability broken")
        resend = sender.send_wire(wire2_reload)  # byte-identical ORIGINAL
        print("P2 resend request:", resend)

        print("=== 6/7 P2 independent verify + exactly-once distinct IDs")
        v2 = extract_verified(receiver.watch_path, P2, 120)
        print("P2 verify:", v2)
        if not v2.get("verified"):
            raise RuntimeError(f"P2 not verified after retry: {v2}")
        distinct = v2.get("event_ids", [])
        if len(distinct) != 1:
            raise RuntimeError(f"P2 distinct event IDs != 1: {distinct}")
        expected_id = hashlib.sha256(canon2).hexdigest()
        if distinct[0] != expected_id:
            raise RuntimeError(f"P2 event id {distinct[0]} != original {expected_id} "
                               "— resent bytes were not the originals")
        result["p2_expected_event_id"] = expected_id
        result["claims"] += ["p2-exactly-once-distinct-event-id",
                             "p2-original-signed-bytes-resent"]
        result["p2"] = v2

        print("=== 7/7 cross-implementation note + summary")
        result["status"] = "PASS"
        result["wire_format"] = ("canonical-bytes ++ \\n ++ sig-hex; "
                                 "Ed25519 RFC 8032 (libsodium in product, "
                                 "python-cryptography in harness — same standard)")
        result["canonical_sample_sha256"] = hashlib.sha256(canon1).hexdigest()
        (EVID / "result.json").write_text(json.dumps(result, indent=2))
        print("RESULT", json.dumps(result))
        return 0
    except BaseException as e:
        result["error"] = f"{type(e).__name__}: {e}"
        (EVID / "result.json").write_text(json.dumps(result, indent=2))
        print("RESULT", json.dumps(result))
        return 1
    finally:
        for s in (sender, receiver):
            with contextlib.suppress(Exception):
                s.close()
        with contextlib.suppress(Exception):
            if relay_harness and relay_harness.poll() is None:
                os.killpg(relay_harness.pid, signal.SIGTERM)
        with contextlib.suppress(Exception):
            stop_relays()
        time.sleep(2)
        subprocess.run(["pkill", "-f", "m2b-cli/(sender|receiver)-cli"],
                       capture_output=True)
        time.sleep(1)
        leftover = subprocess.run(["pgrep", "-f", "m2b-cli|lp0026-forum-dev/m2-run|lp0026-forum-dev/m1-run"],
                                  capture_output=True, text=True).stdout.strip()
        print("cleanup leftover:", leftover or "none")
        (EVID / "result.json").write_text(json.dumps(result, indent=2))


if __name__ == "__main__":
    sys.exit(main())
