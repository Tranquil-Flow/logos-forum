#!/usr/bin/env python3
"""LP-0026 Forum — M1 local transport topology harness.

Starts a bounded local Delivery Mix topology on loopback: four dedicated Mix
relay daemons (logosctl-hosted) plus configuration for two application roles
(the forum module instances). No public bootstrap, no public posting.

Topology facts are validated against the pinned Delivery module v0.3.0: flat
WakuNodeConf config shape, anonymityLevel Required on the sender, mixnodes
entries as multiaddr:mixpublickey, lightpush pinned to the first relay.

Private keys and key-bearing configs live ONLY under the given --state dir
(private state root). Public identifiers (multiaddrs, mix public keys) are
exported to --evidence for the record.

Usage:
  m1_topology.py start  --state DIR --evidence DIR [--runtime DIR]
  m1_topology.py app-config --state DIR --role sender|receiver --out FILE
  m1_topology.py stop   --state DIR
  m1_topology.py status --state DIR
"""
import argparse
import contextlib
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric import ec, x25519
from cryptography.hazmat.primitives import serialization as ser

B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
RELAY_NAMES = ["core1", "core2", "core3", "core4"]
DELIVERY_LGX = os.environ.get(
    "FORUM_DELIVERY_LGX",
    str(Path.home() / ".local/share/lp0026-forum-dev/downloads/delivery_module-0.3.2.lgx"),
)
DEFAULT_RUNTIME = str(Path.home() / ".local/share/lp0026-forum-dev/runtime/logosctl-aarch64-macos")


def b58(raw: bytes) -> str:
    n = int.from_bytes(raw, "big")
    out = ""
    while n:
        n, m = divmod(n, 58)
        out = B58[m] + out
    return "1" * (len(raw) - len(raw.lstrip(b"\0"))) + out


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def identity() -> dict:
    k = ec.generate_private_key(ec.SECP256K1())
    pub = k.public_key().public_bytes(ser.Encoding.X962, ser.PublicFormat.CompressedPoint)
    pb = bytes([8, 2, 18, len(pub)]) + pub
    mk = x25519.X25519PrivateKey.generate()
    return {
        "nodekey": k.private_numbers().private_value.to_bytes(32, "big").hex(),
        "peer": b58(bytes([0, len(pb)]) + pb),
        "mixkey": mk.private_bytes(ser.Encoding.Raw, ser.PrivateFormat.Raw, ser.NoEncryption()).hex(),
        "mixpub": mk.public_key().public_bytes(ser.Encoding.Raw, ser.PublicFormat.Raw).hex(),
        "port": free_port(),
    }


def multiaddr(ids: dict, name: str) -> str:
    return f"/ip4/127.0.0.1/tcp/{ids[name]['port']}/p2p/{ids[name]['peer']}"


def mix_entry(ids: dict, name: str) -> str:
    return multiaddr(ids, name) + ":" + ids[name]["mixpub"]


def relay_config(ids: dict, name: str, state: Path) -> dict:
    """Flat WakuNodeConf shape validated against Delivery v0.3.0."""
    data_dir = state / "delivery-data" / name
    data_dir.mkdir(parents=True, exist_ok=True)
    cfg = {
        "logLevel": "INFO",
        "listenAddress": "127.0.0.1",
        "tcpPort": ids[name]["port"],
        "nodekey": ids[name]["nodekey"],
        "quicSupport": False,
        "nat": "none",
        "clusterId": 42,
        "numShardsInNetwork": 1,
        "relay": True,
        "store": False,
        "filter": False,
        "lightpush": True,
        "peerExchange": False,
        "discv5Discovery": False,
        "enableKadDiscovery": False,
        "rendezvous": False,
        "reliabilityEnabled": False,
        "localStoragePath": str(data_dir),
        "anonymityLevel": "None",
        "staticnodes": [multiaddr(ids, c) for c in RELAY_NAMES if c != name],
        "mix": True,
        "mixkey": ids[name]["mixkey"],
        "mixnodes": [mix_entry(ids, c) for c in RELAY_NAMES if c != name],
    }
    return cfg


def app_config(ids: dict, role: str) -> dict:
    """Config for a forum-module application role (sender or receiver)."""
    assert role in ("sender", "receiver")
    cfg = {
        "logLevel": "INFO",
        "listenAddress": "127.0.0.1",
        "tcpPort": ids[role]["port"],
        "nodekey": ids[role]["nodekey"],
        "quicSupport": False,
        "nat": "none",
        "clusterId": 42,
        "numShardsInNetwork": 1,
        "relay": True,
        "store": False,
        "filter": False,
        "lightpush": False,
        "peerExchange": False,
        "discv5Discovery": False,
        "enableKadDiscovery": False,
        "rendezvous": False,
        "reliabilityEnabled": False,
        "anonymityLevel": "Required" if role == "sender" else "None",
        "staticnodes": [multiaddr(ids, c) for c in RELAY_NAMES],
    }
    if role == "sender":
        cfg.update(
            {
                "mix": True,
                "mixkey": ids[role]["mixkey"],
                "mixnodes": [mix_entry(ids, c) for c in RELAY_NAMES],
                "lightpushnode": multiaddr(ids, "core1"),
            }
        )
    else:
        cfg["mix"] = False
    return cfg


def logosctl(state: Path, runtime: Path) -> list:
    return [str(runtime / "bin" / "logosctl"), "--config-dir", str(state)]


def wait_running(binary_logosctl: list, deadline_s: float = 30) -> bool:
    end = time.time() + deadline_s
    while time.time() < end:
        try:
            out = subprocess.run(
                binary_logosctl + ["status", "--json"],
                capture_output=True, text=True, timeout=10,
            ).stdout
            if '"status":"running"' in out.replace(" ", ""):
                return True
        except subprocess.TimeoutExpired:
            pass
        time.sleep(1.5)
    return False


@contextlib.contextmanager
def relay_sessions(state: Path, runtime: Path, evidence: Path, reuse: bool = False):
    """Start 4 relay daemons; yield pids file; stop them on exit.

    With reuse=True, reloads identities from identities-full.json so restarted
    relays keep the SAME peer ids/mix keys the app instances dial (address
    stability across the M2b restart test).
    """
    # relays.pids is the readiness signal callers wait on: a stale one from a
    # previous run would make them read old identities/ports and dial dead
    # relays (Delivery 0.3.0 never redials). Remove it before anything else.
    (state / "relays.pids").unlink(missing_ok=True)
    full_path = state / "identities-full.json"
    if reuse and full_path.exists():
        ids = json.loads(full_path.read_text())
        print("reusing identities from", full_path, flush=True)
    else:
        ids = {n: identity() for n in RELAY_NAMES + ["sender", "receiver"]}
        (state / "identities-full.json").write_text(json.dumps(ids, indent=2))
        os.chmod(state / "identities-full.json", 0o600)
    (state / "identities.json").write_text(json.dumps(
        {n: {k: v for k, v in ids[n].items() if k != "nodekey" and k != "mixkey"}
         for n in ids}, indent=2))
    os.chmod(state / "identities.json", 0o644)
    pids = {}
    started = []
    try:
        for n in RELAY_NAMES:
            sdir = state / "relays" / n
            sdir.mkdir(parents=True, exist_ok=True)
            ctl = logosctl(sdir, runtime)
            # Order matters: the daemon must be running before package install
            # (logosctl client talks to the session daemon — NO_DAEMON otherwise).
            subprocess.run(ctl + ["-d", "daemon", "start"],
                           capture_output=True, text=True, check=True, timeout=60)
            if not wait_running(ctl):
                raise RuntimeError(f"relay {n} daemon did not reach running state")
            # Install the pinned delivery module (authoritative install path).
            inst = subprocess.run(ctl + ["install", "-y", DELIVERY_LGX],
                                  capture_output=True, text=True, timeout=180)
            if inst.returncode != 0 or '"status":"error"' in inst.stdout.replace(" ", ""):
                raise RuntimeError(f"relay {n} install failed: {inst.stdout[-400:]} {inst.stderr[-400:]}")
            subprocess.run(ctl + ["module", "load", "delivery_module"],
                           capture_output=True, text=True, check=True, timeout=60)
            cfg = relay_config(ids, n, state)
            cfg_path = sdir / "node-config.json"
            cfg_path.write_text(json.dumps(cfg))
            os.chmod(cfg_path, 0o600)
            subprocess.run(ctl + ["call", "delivery_module", "createNode", f"@{cfg_path}"],
                           capture_output=True, text=True, check=True, timeout=60)
            subprocess.run(ctl + ["call", "delivery_module", "start"],
                           capture_output=True, text=True, check=True, timeout=60)
            st = json.loads(subprocess.run(ctl + ["status", "--json"],
                                           capture_output=True, text=True, timeout=30).stdout)
            pids[n] = st["daemon"]["pid"]
            started.append(n)
            print(f"relay {n} up pid={pids[n]} port={ids[n]['port']}", flush=True)
        # Publish readiness only once every relay listener accepts TCP.
        waiting = {n: ids[n]["port"] for n in RELAY_NAMES}
        deadline = time.time() + 60
        while waiting and time.time() < deadline:
            for n, port in list(waiting.items()):
                with socket.socket() as sock:
                    sock.settimeout(1)
                    if sock.connect_ex(("127.0.0.1", port)) == 0:
                        del waiting[n]
            if waiting:
                time.sleep(1)
        if waiting:
            raise RuntimeError(f"relay listeners not accepting: {sorted(waiting)}")
        print("relay listeners accepting on all ports", flush=True)
        (state / "relays.pids").write_text(json.dumps(pids))
        # Public identifiers only — safe for evidence.
        (evidence / "topology.json").write_text(json.dumps({
            "layer": "local-loopback-delivery-mix",
            "relays": {n: {"multiaddr": multiaddr(ids, n), "mix_public_key": ids[n]["mixpub"]}
                       for n in RELAY_NAMES},
            "apps": {r: {"multiaddr": multiaddr(ids, r),
                         "anonymity_level": "Required" if r == "sender" else "None",
                         "mix_public_key": ids[r]["mixpub"] if r == "sender" else None}
                     for r in ("sender", "receiver")},
            "limits": {"public_peers": 0, "relay_nodes": 4, "payload_cap": "50 labelled posts / 5 MiB"},
        }, indent=2))
        yield ids
    finally:
        (state / "relays.pids").unlink(missing_ok=True)
        for n in started:
            sdir = state / "relays" / n
            ctl = logosctl(sdir, runtime)
            with contextlib.suppress(Exception):
                subprocess.run(ctl + ["call", "delivery_module", "stop"],
                               capture_output=True, text=True, timeout=30)
            with contextlib.suppress(Exception):
                subprocess.run(ctl + ["daemon", "stop"],
                               capture_output=True, text=True, timeout=30)
        time.sleep(2)
        # Verify cleanup of owned processes.
        survivors = []
        for n in started:
            pid = pids.get(n)
            if pid and Path(f"/proc/{pid}").exists():
                survivors.append(pid)
            # macOS: ps check
            r = subprocess.run(["ps", "-p", str(pid)], capture_output=True, text=True)
            if r.stdout and str(pid) in r.stdout:
                survivors.append(pid)
        if survivors:
            print(f"WARNING: relay pids still alive after stop: {sorted(set(survivors))}", flush=True)
            for pid in sorted(set(survivors)):
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)
        else:
            print("cleanup verified: no relay processes remain", flush=True)


def cmd_start(args):
    state = Path(args.state)
    evidence = Path(args.evidence)
    runtime = Path(args.runtime)
    state.mkdir(parents=True, exist_ok=True)
    evidence.mkdir(parents=True, exist_ok=True)
    with relay_sessions(state, runtime, evidence, reuse=args.reuse) as ids:
        print("topology up; relays stop when this process exits", flush=True)
        print("PID", os.getpid(), flush=True)
        while True:
            time.sleep(5)


def cmd_app_config(args):
    state = Path(args.state)
    # Full identities (including private keys) from the private state file.
    full = json.loads((state / "identities-full.json").read_text())
    cfg = app_config(full, args.role)
    out = Path(args.out)
    out.write_text(json.dumps(cfg))
    os.chmod(out, 0o600)
    print(f"wrote {out} for role {args.role} (mode 0600)")


def cmd_stop(args):
    state = Path(args.state)
    pids_path = state / "relays.pids"
    if not pids_path.exists():
        print("no relays.pids — nothing to stop")
        return
    pids = json.loads(pids_path.read_text())
    for n, pid in pids.items():
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, sig)
            time.sleep(1)
            r = subprocess.run(["ps", "-p", str(pid)], capture_output=True, text=True)
            if not (r.stdout and str(pid) in r.stdout):
                break
    pids_path.unlink(missing_ok=True)
    print("stop issued for:", ", ".join(pids))


def cmd_status(args):
    state = Path(args.state)
    pids_path = state / "relays.pids"
    if not pids_path.exists():
        print("no relays.pids")
        return
    pids = json.loads(pids_path.read_text())
    for n, pid in pids.items():
        r = subprocess.run(["ps", "-p", str(pid)], capture_output=True, text=True)
        alive = bool(r.stdout and str(pid) in r.stdout)
        print(f"{n}: pid={pid} {'alive' if alive else 'dead'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--evidence", default=None)
    ap.add_argument("--runtime", default=DEFAULT_RUNTIME)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp_start = sub.add_parser("start")
    sp_start.add_argument("--reuse", action="store_true",
                          help="reload identities from identities-full.json")
    sub.add_parser("stop")
    sub.add_parser("status")
    ac = sub.add_parser("app-config")
    ac.add_argument("--role", required=True, choices=["sender", "receiver"])
    ac.add_argument("--out", required=True)
    args = ap.parse_args()
    if args.cmd == "start":
        if not args.evidence:
            ap.error("start requires --evidence")
        cmd_start(args)
    elif args.cmd == "stop":
        cmd_stop(args)
    elif args.cmd == "status":
        cmd_status(args)
    elif args.cmd == "app-config":
        cmd_app_config(args)


if __name__ == "__main__":
    main()
