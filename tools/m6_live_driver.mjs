#!/usr/bin/env node
// LP-0026 Forum — live public-network driver (logos.dev, Mix Required).
//
// Drives two running app instances that have NO transport config: each one
// must join the network through the in-app "Connect to Logos network" action,
// exactly as a user would. Then A posts and B must render the post as
// [received]. Usage:
//   node tools/m6_live_driver.mjs --a-port 3768 --b-port 3769 --text "<post>" \
//     [--ready-wait 180000] [--wait 300000]
import net from "node:net";
const SANDBOX = "root.backend.openTopic(root.topics.filter(function (t) { return t.indexOf('|Sandbox (') > 0 })[0].split('|')[0])";

const args = process.argv.slice(2);
function arg(name, dflt) {
  const i = args.indexOf("--" + name);
  return i >= 0 ? args[i + 1] : dflt;
}
const aPort = parseInt(arg("a-port", "3768"), 10);
const bPort = parseInt(arg("b-port", "3769"), 10);
const postText = arg("text", "TECHNICAL TEST DATA: live logos.dev round trip");
const readyWait = parseInt(arg("ready-wait", "180000"), 10);
const waitMs = parseInt(arg("wait", "300000"), 10);
const t0 = Date.now();
const elapsed = () => Math.round((Date.now() - t0) / 1000);

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

const result = { status: "FAIL", layer: "public-logos.dev-mix-required", text: postText, timeline: [] };
const mark = (what, extra = {}) => { result.timeline.push({ t_s: elapsed(), what, ...extra }); };
const a = new Client(aPort);
const b = new Client(bPort);
const evalStr = async (c, expr) => String((await c.send("evaluate", { expression: expr })).result ?? "");
try {
  await a.connect();
  await b.connect();
  await waitFor(async () => a.expectTexts(["Module ready"]), 30000, "A backend");
  await waitFor(async () => b.expectTexts(["Module ready"]), 30000, "B backend");
  // Test posts go to the shared Sandbox topic, never General.
  for (const x of [a, b]) {
    await x.send("evaluate", { expression: SANDBOX });
    await waitFor(async () => {
      const r = await x.send("evaluate", { expression: "root.currentTopicTitle" });
      if (r.result !== "Sandbox") throw new Error("not in Sandbox: " + JSON.stringify(r));
    }, 10000, "Sandbox open");
  }
  result.a_initial_state = await evalStr(a, "transportState");
  result.b_initial_state = await evalStr(b, "transportState");
  if (/^transport ready/.test(result.a_initial_state) || /^transport ready/.test(result.b_initial_state)) {
    throw new Error("an instance was connected before the user asked — join must be explicit");
  }
  // The user action: press Connect on both instances.
  await a.send("evaluate", { expression: "connectButton.clicked()" });
  mark("A connect clicked");
  await b.send("evaluate", { expression: "connectButton.clicked()" });
  mark("B connect clicked");
  // A writes immediately — before the network is ready. The post must be
  // stored and queued, then sent automatically once connected (no manual retry).
  const found = await a.send("findByProperty", { property: "placeholderText", value: "Write a post (plain text)" });
  if (found.error || !found.matches || !found.matches.length) throw new Error("composer not found");
  const set = await a.send("setProperty", { objectId: found.matches[0].id, property: "text", value: postText });
  if (set.error) throw new Error("setProperty: " + set.error);
  await a.send("evaluate", { expression: "sendButton.clicked()" });
  mark("A post clicked (before ready)");
  result.a_post_outcome = await evalStr(a, "outcome.text");
  result.a_thread_at_post = await evalStr(a, "JSON.stringify(threadPosts)");
  result.a_connection_at_post = await evalStr(a, "root.connection");
  for (const [name, c] of [["A", a], ["B", b]]) {
    await waitFor(async () => {
      const s = await evalStr(c, "transportState");
      if (!/^transport ready/.test(s) && !/sending|propagated|validated/.test(s)) throw new Error(name + " state: " + s.slice(0, 300));
    }, readyWait, name + " transport ready");
    result[name.toLowerCase() + "_ready_state"] = await evalStr(c, "transportState");
    mark(name + " connected", { connection: await evalStr(c, "root.connection") });
  }
  const states = [];
  await waitFor(async () => {
    const s = await evalStr(a, "transportState");
    if (states[states.length - 1] !== s) { states.push(s); mark("A state", { state: s.slice(0, 300) }); }
    if (/propagated|validated by network/i.test(s)) return;
    throw new Error("A state: " + s.slice(0, 300));
  }, waitMs, "A propagation");
  result.a_states = states;
  result.manual_retries = 0;
  result.a_propagated = true;
  await waitFor(async () => {
    const rows = await evalStr(b, "JSON.stringify(threadPosts)");
    if (!rows.includes("[received]: " + postText)) throw new Error("B thread: " + rows.slice(0, 300));
  }, waitMs, "B render");
  mark("B rendered [received]");
  result.b_rendered = true;
  result.a_thread = await evalStr(a, "JSON.stringify(threadPosts)");
  result.b_thread = await evalStr(b, "JSON.stringify(threadPosts)");
  result.status = "PASS";
} catch (e) {
  result.error = String((e && e.message) || e);
  try { result.a_last_state = await evalStr(a, "transportState"); } catch {}
  try { result.b_last_state = await evalStr(b, "transportState"); } catch {}
  try { result.a_thread = await evalStr(a, "JSON.stringify(threadPosts)"); } catch {}
  try { result.b_thread = await evalStr(b, "JSON.stringify(threadPosts)"); } catch {}
} finally {
  a.disconnect();
  b.disconnect();
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.status === "PASS" ? 0 : 1);
}
