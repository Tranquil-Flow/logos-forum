#!/usr/bin/env node
// LP-0026 Forum — M1 two-instance transport driver.
//
// Self-contained Qt Inspector client (newline-JSON protocol) so one process
// can drive BOTH app instances on different ports. The framework's Inspector
// reads QML_INSPECTOR_PORT once at import, which cannot address two hosts.
//
// Usage:
//   node tools/m1_ui_driver.mjs --sender-port 3768 --receiver-port 3769 \
//     --text "<post text>" [--wait 60000]
//
// Both standalone-app instances must already be running with
// FORUM_TRANSPORT_CONFIG set and the inspector enabled.
import net from "node:net";

const args = process.argv.slice(2);
function arg(name, dflt) {
  const i = args.indexOf("--" + name);
  return i >= 0 ? args[i + 1] : dflt;
}
const senderPort = parseInt(arg("sender-port", "3768"), 10);
const receiverPort = parseInt(arg("receiver-port", "3769"), 10);
const postText = arg("text", "TECHNICAL TEST DATA: M1 Required-send round trip");
const waitMs = parseInt(arg("wait", "90000"), 10);

class Client {
  constructor(port) {
    this.port = port;
    this.id = 0;
    this.pending = new Map();
    this.buffer = "";
    this.socket = null;
  }
  connect() {
    return new Promise((resolve, reject) => {
      const sock = net.createConnection({ host: "localhost", port: this.port });
      sock.once("connect", () => { this.socket = sock; resolve(); });
      sock.once("error", (e) => reject(new Error(`inspector :${this.port}: ${e.message}`)));
      sock.on("data", (chunk) => {
        this.buffer += chunk.toString("utf-8");
        let idx;
        while ((idx = this.buffer.indexOf("\n")) >= 0) {
          const line = this.buffer.slice(0, idx).trim();
          this.buffer = this.buffer.slice(idx + 1);
          if (!line) continue;
          try {
            const msg = JSON.parse(line);
            const p = this.pending.get(String(msg.id));
            if (p) { this.pending.delete(String(msg.id)); p.resolve(msg); }
          } catch { /* skip malformed */ }
        }
      });
    });
  }
  send(command, params = {}) {
    const id = ++this.id;
    const payload = JSON.stringify({ id, command, params }) + "\n";
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`timeout: ${command} :${this.port}`));
      }, 20000);
      this.pending.set(String(id), { resolve, timer });
      this.socket.write(payload);
    });
  }
  async findByText(text) {
    const res = await this.send("findByProperty", { property: "text", value: text });
    return res;
  }
  async expectTexts(texts) {
    const missing = [];
    for (const t of texts) {
      const res = await this.findByText(t);
      if (res.error || !res.matches || res.matches.length === 0) missing.push(t);
    }
    if (missing.length) throw new Error(`texts not found: ${JSON.stringify(missing)}`);
  }
  async click(text) {
    const res = await this.send("findAndClick", { text });
    if (res.error) throw new Error(`click(${text}): ${res.error}`);
  }
  disconnect() { if (this.socket) this.socket.destroy(); }
}

async function waitFor(fn, timeoutMs, description) {
  const start = Date.now();
  let lastErr;
  while (Date.now() - start < timeoutMs) {
    try { await fn(); return; } catch (e) {
      lastErr = e;
      await new Promise((r) => setTimeout(r, 500));
    }
  }
  throw new Error(`timeout waiting for ${description}: ${lastErr && lastErr.message}`);
}

const result = { status: "FAIL", text: postText, sender_port: senderPort, receiver_port: receiverPort };
const sender = new Client(senderPort);
const receiver = new Client(receiverPort);
try {
  await sender.connect();
  await receiver.connect();

  await waitFor(async () => sender.expectTexts(["Module ready"]), 30000, "sender backend");
  await waitFor(async () => receiver.expectTexts(["Module ready"]), 30000, "receiver backend");

  // Sender: set composer text + click Post (real QML interactions).
  const found = await sender.send("findByProperty", {
    property: "placeholderText", value: "Write a post (plain text)",
  });
  if (found.error || !found.matches || !found.matches.length) throw new Error("composer not found");
  const set = await sender.send("setProperty", {
    objectId: found.matches[0].id, property: "text", value: postText,
  });
  if (set.error) throw new Error("setProperty: " + set.error);
  await sender.send("evaluate", { expression: "sendButton.clicked()" });

  // Sender transport state must reach a propagation/validation event —
  // honest state from real module events, not from configuration alone.
  await waitFor(async () => {
    const t = await sender.send("evaluate", { expression: "transportState" });
    const s = JSON.stringify(t);
    if (!/propagated|validated by network/i.test(s)) {
      throw new Error("sender transport state: " + s.slice(0, 300));
    }
  }, waitMs, "sender propagation state");
  result.sender_propagated = true;

  // Receiver: the post must render in its thread (rows are "alias [state]: body";
  // the shared General topic means both instances show the same thread).
  await waitFor(async () => {
    const r = await receiver.send("evaluate", { expression: "JSON.stringify(threadPosts)" });
    const rows = String(r.result ?? "");
    if (!rows.includes("[received]: " + postText)) throw new Error("receiver thread: " + rows.slice(0, 300));
  }, waitMs, "receiver render");
  result.receiver_rendered = true;

  // Coexistence guard: re-probe must confirm the APP-OWNED node (not a
  // foreign one) — the honest branch of the shared-host safety check.
  await sender.send("evaluate", { expression: "recheckButton.clicked()" });
  await waitFor(async () => {
    const t = await sender.send("evaluate", { expression: "transportState" });
    const s = JSON.stringify(t);
    if (!/app-owned node confirmed/.test(s)) {
      throw new Error("recheck state: " + s.slice(0, 300));
    }
  }, 30000, "recheck confirms app-owned node");
  result.recheck_confirmed_own_node = true;

  result.status = "PASS";
} catch (e) {
  result.error = String((e && e.message) || e);
} finally {
  sender.disconnect();
  receiver.disconnect();
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.status === "PASS" ? 0 : 1);
}
